import Foundation
import CryptoKit
import Compression

/// Native reimplementation of the `aze` elevation protocol, so FleetMate has no
/// dependency on the external `~/bin/aze` script. The container lifecycle and
/// the exec handshake go through the `az` CLI (which we deliberately keep); only
/// the raw exec websocket is driven natively here.
///
/// Security model is unchanged: this rides the operator's own `az login` on a
/// compliant device and their elevation operators-group membership. The app is
/// not a privilege — an unauthorized caller's `az` calls simply fail.
public actor ElevationSession {
    // Constants mirrored from the aze script.
    static let sessionsResourceGroup = "Entra"
    static let identityResourceGroup = "Entra"
    static let image = "elevationregistryecu.azurecr.io/elevation-session:latest"
    static let transcriptAccount = "elevationtranscripts"
    public static let defaultTtlHours = 8
    static let execApiVersion = "2023-05-01"

    private let azPath: String

    public init(azPath: String? = nil) {
        self.azPath = azPath ?? ElevationSession.locateAz()
    }

    static func locateAz() -> String {
        for candidate in ["/opt/homebrew/bin/az", "/usr/local/bin/az"] where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "az"
    }

    static func identityName(for domain: GraphDomain) -> String {
        switch domain {
        case .terraform: return "DevOps-Terraform"
        case .devices: return "DevOps-Devices"
        case .identity: return "DevOps-Identity"
        case .systems: return "DevOps-Systems"
        case .cloud: return "DevOps-Cloud"
        }
    }

    static func sessionName(for domain: GraphDomain) -> String {
        let user = String(NSUserName().lowercased().filter { $0.isLetter || $0.isNumber }.prefix(20))
        return "aze-\(domain.rawValue)-\(user)"
    }

    // MARK: - Container lifecycle (via az)

    /// Ensure a running session container for the domain, creating it (cold
    /// start, ~30s) if absent.
    public func ensureSession(_ domain: GraphDomain, ttlHours: Int = ElevationSession.defaultTtlHours) async throws {
        let name = ElevationSession.sessionName(for: domain)

        let show = try await runAz(["container", "show", "--resource-group", ElevationSession.sessionsResourceGroup, "--name", name, "--query", "instanceView.state", "-o", "tsv"])
        let state = show.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if state == "Running" { return }

        if !state.isEmpty {
            _ = try await runAz(["container", "delete", "--resource-group", ElevationSession.sessionsResourceGroup, "--name", name, "--yes", "-o", "none"])
        }

        // Resolve the user-assigned identity id + clientId in one round-trip.
        let idShow = try await runAz(["identity", "show", "--resource-group", ElevationSession.identityResourceGroup, "--name", ElevationSession.identityName(for: domain), "--query", "[id,clientId]", "-o", "tsv"])
        let parts = idShow.out.split(whereSeparator: { $0 == "\t" || $0 == "\n" }).map(String.init)
        guard parts.count >= 2 else { throw ElevationError.identityResolutionFailed(domain) }
        let identityId = parts[0], clientId = parts[1]

        let sleepSeconds = ttlHours * 3600
        let commandLine = "/bin/bash -c 'az login --identity --client-id \(clientId) --allow-no-subscriptions -o none; sleep \(sleepSeconds)'"

        let create = try await runAz([
            "container", "create",
            "--resource-group", ElevationSession.sessionsResourceGroup,
            "--name", name,
            "--image", ElevationSession.image,
            "--assign-identity", identityId,
            "--acr-identity", identityId,
            "--os-type", "Linux",
            "--cpu", "1",
            "--memory", "1.5",
            "--restart-policy", "Never",
            "--command-line", commandLine,
            "--environment-variables", "ELEVATION_CLIENT_ID=\(clientId)", "ELEVATION_TRANSCRIPT_ACCOUNT=\(ElevationSession.transcriptAccount)",
            "--output", "none",
        ])
        guard create.code == 0 else { throw ElevationError.createFailed(create.err.isEmpty ? create.out : create.err) }

        // az container create has no --tags; tag in a follow-up call (best-effort).
        let idLookup = try? await runAz(["container", "show", "--resource-group", ElevationSession.sessionsResourceGroup, "--name", name, "--query", "id", "-o", "tsv"])
        if let containerId = idLookup?.out.trimmingCharacters(in: .whitespacesAndNewlines), !containerId.isEmpty {
            let expires = Int(Date().timeIntervalSince1970) + sleepSeconds
            _ = try? await runAz(["resource", "tag", "--ids", containerId, "--tags", "elevation=true", "domain=\(domain.rawValue)", "expires=\(expires)", "--output", "none"])
        }
    }

    // MARK: - Exec (handshake via az, raw websocket native)

    /// Run a single-line command inside the session and return its stdout +
    /// exit code, mirroring `aze run`.
    ///
    /// The exec container cannot service concurrent commands: every exec opens a
    /// pseudo-terminal on the same session, and two commands running at once
    /// interleave their output on that shared stream, corrupting both payloads
    /// (an `az rest` JSON response comes back spliced with another command's
    /// bytes and fails to decode). Callers legitimately fan out — the app fires
    /// several Graph/Intune fetches at launch — so we serialize per domain
    /// through a process-wide gate. Different domains hit different containers
    /// and still run concurrently.
    public func exec(_ domain: GraphDomain, command: String, ttlHours: Int? = nil) async throws -> (out: String, code: Int32) {
        await ElevationSessionGate.shared.acquire(domain)
        do {
            let result = try await runExec(domain, command: command, ttlHours: ttlHours)
            await ElevationSessionGate.shared.release(domain)
            return result
        } catch {
            await ElevationSessionGate.shared.release(domain)
            throw error
        }
    }

    /// The ACI exec pty→websocket bridge drops bytes intermittently under load
    /// (~2% per KB, even with no concurrency), so any payload past a few KB
    /// arrives corrupt and cannot be carried whole. Instead the container writes
    /// its stdout to a temp file and serves it as small, individually-checksummed
    /// base64 chunks; the client keeps the chunks whose MD5 matches and re-serves
    /// only the ones the pty mangled, from the same stable file. A full device
    /// page converges in ~2–3 round trips; small results (login probes,
    /// single-device lookups) come back in one chunk, one trip.
    static let maxExecAttempts = 6
    static let chunkBytes = 4096
    static let maxChunkPasses = 8

    private func runExec(_ domain: GraphDomain, command: String, ttlHours: Int? = nil) async throws -> (out: String, code: Int32) {
        try await ensureSession(domain, ttlHours: ttlHours ?? ElevationSession.defaultTtlHours)
        let name = ElevationSession.sessionName(for: domain)

        let account = try await runAz(["account", "show", "--query", "id", "-o", "tsv"])
        let sub = account.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard account.code == 0, !sub.isEmpty else {
            throw ElevationError.execHandshakeFailed("Not logged in to az (run az login). \(account.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let uri = "https://management.azure.com/subscriptions/\(sub)/resourceGroups/\(ElevationSession.sessionsResourceGroup)/providers/Microsoft.ContainerInstance/containerGroups/\(name)/containers/\(name)/exec?api-version=\(ElevationSession.execApiVersion)"
        let body = "{\"command\":\"/bin/bash\",\"terminalSize\":{\"rows\":24,\"cols\":500}}"

        let chunk = ElevationSession.chunkBytes
        let file = "/tmp/aze_\(UUID().uuidString)"
        // The chunked, served file holds the raw-DEFLATE-compressed payload;
        // meta carries both the compressed size/hash (to reassemble the transfer)
        // and the original size/hash (to verify after inflation).
        var meta: (code: Int32, compTotal: Int, compMd5: String, rawLen: Int, rawMd5: String)?
        var chunks: [Int: Data] = [:]

        // Phase 1 — produce: run the command into the file and emit META + every
        // chunk. Retry the whole produce until the (tiny) META header parses.
        let produceCmd = ElevationSession.buildProduce(command: command, file: file, chunk: chunk)
        var lastError: Error = ElevationError.noOutputMarkers("no produce attempt succeeded")
        for _ in 0..<ElevationSession.maxExecAttempts {
            let text: String
            do {
                text = try await handshakeAndRun(uri: uri, body: body, command: produceCmd)
            } catch let error as ElevationError where !error.isCaptureFailure {
                throw error // handshake / identity failures are not worth re-running
            } catch {
                lastError = error
                continue
            }
            if let m = ElevationSession.parseMeta(text) {
                meta = m
                chunks = [:]
                for (i, d) in ElevationSession.parseChunks(text) { chunks[i] = d }
                break
            }
            lastError = ElevationError.noOutputMarkers(String(text.prefix(200)))
        }
        guard let m = meta else { throw lastError }
        let expected = m.compTotal == 0 ? 0 : (m.compTotal + chunk - 1) / chunk

        // Phase 2 — re-serve only the chunks the pty mangled, from the same file.
        for _ in 0..<ElevationSession.maxChunkPasses {
            let missing = (0..<expected).filter { chunks[$0] == nil }
            if missing.isEmpty { break }
            let reserveCmd = ElevationSession.buildReserve(file: file, chunk: chunk, indices: missing)
            let text = try await handshakeAndRun(uri: uri, body: body, command: reserveCmd)
            for (i, d) in ElevationSession.parseChunks(text) where i < expected { chunks[i] = d }
        }

        let stillMissing = (0..<expected).filter { chunks[$0] == nil }
        guard stillMissing.isEmpty else {
            throw ElevationError.corruptedOutput(expected: expected, actual: expected - stillMissing.count)
        }

        var compressed = Data()
        compressed.reserveCapacity(m.compTotal)
        for i in 0..<expected { compressed.append(chunks[i]!) }
        let compDigest = Insecure.MD5.hash(data: compressed).map { String(format: "%02x", $0) }.joined()
        guard compressed.count == m.compTotal, compDigest == m.compMd5 else {
            throw ElevationError.corruptedOutput(expected: m.compTotal, actual: compressed.count)
        }

        // Inflate (raw DEFLATE) and verify against the original size + hash.
        guard let raw = ElevationSession.inflateRaw(compressed, expectedSize: m.rawLen) else {
            throw ElevationError.corruptedOutput(expected: m.rawLen, actual: -1)
        }
        let rawDigest = Insecure.MD5.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        guard raw.count == m.rawLen, rawDigest == m.rawMd5 else {
            throw ElevationError.corruptedOutput(expected: m.rawLen, actual: raw.count)
        }
        return (String(decoding: raw, as: UTF8.self), m.code)
    }

    /// Open one exec websocket and run a single self-terminating command
    /// (ends in `<<<AZE_DONE>>>` then `exit`). Retries only the handshake POST,
    /// which occasionally fails transiently; the returned text may still contain
    /// mangled chunks — that is handled by the chunk layer above.
    private func handshakeAndRun(uri: String, body: String, command: String) async throws -> String {
        var lastError: Error = ElevationError.execHandshakeFailed("no handshake attempt")
        for _ in 0..<3 {
            let execResp = try await runAz(["rest", "--method", "post", "--uri", uri, "--body", body])
            guard execResp.code == 0,
                  let data = execResp.out.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let wsString = json["webSocketUri"] as? String,
                  let wsURL = URL(string: wsString),
                  let password = json["password"] as? String else {
                lastError = ElevationError.execHandshakeFailed(execResp.err.isEmpty ? execResp.out : execResp.err)
                continue
            }
            return try await runWebSocket(url: wsURL, password: password, command: command)
        }
        throw lastError
    }

    private func runWebSocket(url: URL, password: String, command: String) async throws -> String {
        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: url)
        ws.resume()
        defer { ws.cancel(with: .normalClosure, reason: nil) }

        try await ws.send(.string(password))
        try await ws.send(.string("stty -echo\n"))
        // Wait for the shell to actually be ready to accept input rather than
        // guessing with a fixed sleep (a command sent too early is silently
        // dropped). Send a readiness probe and hold the command until the marker
        // echoes back — as fast as the shell allows, with a bounded fallback.
        try await ws.send(.string("printf '<<<AZE_RDY>>>\\n'\n"))

        var raw = ""
        var sentCommand = false
        let readyDeadline = Date().addingTimeInterval(15)
        let deadline = Date().addingTimeInterval(3600)
        while Date() < deadline {
            if !sentCommand, raw.range(of: "<<<AZE_RDY>>>") != nil || Date() > readyDeadline {
                try await ws.send(.string(command))
                sentCommand = true
            }
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await ws.receive()
            } catch {
                break // closed (the command's `exit`) or errored — parse what we have
            }
            switch message {
            case .string(let s): raw += s
            case .data(let d): raw += String(decoding: d, as: UTF8.self)
            @unknown default: break
            }
            if sentCommand, raw.range(of: "<<<AZE_DONE>>>") != nil { break }
        }
        return ElevationSession.stripAnsi(raw).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: - Helpers

    static let metaRegex = try! NSRegularExpression(pattern: "<<<AZE_META:(\\d+):(\\d+):([0-9a-f]+):(\\d+):([0-9a-f]+)>>>")
    static let chunkRegex = try! NSRegularExpression(pattern: "<<<AZE_C:(\\d+):([0-9a-f]+)>>>([A-Za-z0-9+/=]*)<<<CE>>>")

    /// Produce command: capture stdout to a stable file (folding in stderr only on
    /// failure), print a MD5+length header, then emit every `chunk`-byte slice as
    /// base64 tagged with its own MD5. A stale-file sweep keeps /tmp bounded. Each
    /// slice is independently verifiable, so a byte the pty drops invalidates just
    /// that slice. `md5sum`/`base64`/`tail`/`head`/`wc` are coreutils in the image.
    /// The `<<<` / `>>>` sentinel fences are assembled from shell variables at
    /// runtime (`L`/`R`) so the literal marker strings never appear in the command
    /// source. If `stty -echo` hasn't taken effect yet the shell echoes the
    /// command, and that echo must not contain a real `<<<AZE_DONE>>>` (etc.) or
    /// the client would match it and return before the command even runs.
    static let markerVars = "L='<<<'; R='>>>'; "

    /// Compress the command's stdout with raw DEFLATE (via python's zlib, present
    /// in the azure-cli image) before chunking — a JSON device page shrinks ~8×,
    /// so far fewer bytes cross the lossy pty. `$f` holds the compressed stream
    /// that gets chunked and served; META carries the compressed size/MD5 (to
    /// rebuild the transfer) and the original size/MD5 (to verify after inflate).
    static func buildProduce(command: String, file: String, chunk: Int) -> String {
        ElevationSession.markerVars
            + "find /tmp -maxdepth 1 -name 'aze_*' -mmin +30 -delete 2>/dev/null; "
            + "r=\(file).raw; f=\(file); ( \(command) ) >\"$r\" 2>/tmp/aze_err; c=$?; "
            + "[ \"$c\" -ne 0 ] && cat /tmp/aze_err >>\"$r\"; "
            + "python3 -c 'import zlib,sys; d=sys.stdin.buffer.read(); co=zlib.compressobj(6,zlib.DEFLATED,-15); sys.stdout.buffer.write(co.compress(d)+co.flush())' <\"$r\" >\"$f\"; "
            + "rt=$(wc -c <\"$r\" | tr -d ' '); rm=$(md5sum \"$r\" | cut -d' ' -f1); "
            + "ct=$(wc -c <\"$f\" | tr -d ' '); cm=$(md5sum \"$f\" | cut -d' ' -f1); "
            + "printf '\\n%sAZE_META:%s:%s:%s:%s:%s%s\\n' \"$L\" \"$c\" \"$ct\" \"$cm\" \"$rt\" \"$rm\" \"$R\"; "
            + "o=0; i=0; while [ \"$o\" -lt \"$ct\" ]; do "
            + "d=$(tail -c +$((o+1)) \"$f\" | head -c \(chunk) | base64 | tr -d '\\n'); "
            + "k=$(printf %s \"$d\" | md5sum | cut -d' ' -f1); "
            + "printf '%sAZE_C:%s:%s%s%s%sCE%s\\n' \"$L\" \"$i\" \"$k\" \"$R\" \"$d\" \"$L\" \"$R\"; "
            + "o=$((o+\(chunk))); i=$((i+1)); done; "
            + "printf '%sAZE_DONE%s\\n' \"$L\" \"$R\"; exit\n"
    }

    /// Re-serve specific chunk indices from the compressed file produce wrote.
    static func buildReserve(file: String, chunk: Int, indices: [Int]) -> String {
        let list = indices.map(String.init).joined(separator: " ")
        return ElevationSession.markerVars
            + "f=\(file); for i in \(list); do "
            + "o=$((i*\(chunk))); "
            + "d=$(tail -c +$((o+1)) \"$f\" | head -c \(chunk) | base64 | tr -d '\\n'); "
            + "k=$(printf %s \"$d\" | md5sum | cut -d' ' -f1); "
            + "printf '%sAZE_C:%s:%s%s%s%sCE%s\\n' \"$L\" \"$i\" \"$k\" \"$R\" \"$d\" \"$L\" \"$R\"; "
            + "done; printf '%sAZE_DONE%s\\n' \"$L\" \"$R\"; exit\n"
    }

    /// Inflate a raw-DEFLATE stream (RFC 1951, matching python's `wbits=-15`).
    static func inflateRaw(_ data: Data, expectedSize: Int) -> Data? {
        if expectedSize == 0 { return Data() }
        guard !data.isEmpty else { return nil }
        var out = Data(count: expectedSize)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                compression_decode_buffer(
                    dst.baseAddress!.assumingMemoryBound(to: UInt8.self), expectedSize,
                    src.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        return written == expectedSize ? out : nil
    }

    static func stripAnsi(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\x1b\\[[0-9;?]*[a-zA-Z]") else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    /// Parse the produce header: exit code, compressed size + MD5 (the chunked
    /// transfer), and original size + MD5 (verified after inflation).
    static func parseMeta(_ text: String) -> (code: Int32, compTotal: Int, compMd5: String, rawLen: Int, rawMd5: String)? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = ElevationSession.metaRegex.firstMatch(in: text, range: range),
              let codeRange = Range(m.range(at: 1), in: text),
              let compTotalRange = Range(m.range(at: 2), in: text),
              let compMd5Range = Range(m.range(at: 3), in: text),
              let rawLenRange = Range(m.range(at: 4), in: text),
              let rawMd5Range = Range(m.range(at: 5), in: text) else { return nil }
        return (Int32(text[codeRange]) ?? 0,
                Int(text[compTotalRange]) ?? 0, String(text[compMd5Range]),
                Int(text[rawLenRange]) ?? 0, String(text[rawMd5Range]))
    }

    /// Extract every intact chunk: (index, decoded bytes). A chunk is kept only if
    /// the received base64 still matches the MD5 the container stamped on it and
    /// decodes cleanly; anything the pty mangled is silently dropped and will be
    /// re-served.
    static func parseChunks(_ text: String) -> [(Int, Data)] {
        var out: [(Int, Data)] = []
        let range = NSRange(text.startIndex..., in: text)
        ElevationSession.chunkRegex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match,
                  let idxRange = Range(match.range(at: 1), in: text),
                  let md5Range = Range(match.range(at: 2), in: text),
                  let dataRange = Range(match.range(at: 3), in: text),
                  let idx = Int(text[idxRange]) else { return }
            let declaredMd5 = String(text[md5Range])
            let b64 = String(text[dataRange])
            let digest = Insecure.MD5.hash(data: Data(b64.utf8)).map { String(format: "%02x", $0) }.joined()
            guard digest == declaredMd5, let decoded = Data(base64Encoded: b64) else { return }
            out.append((idx, decoded))
        }
        return out
    }

    private func runAz(_ args: [String]) async throws -> (out: String, err: String, code: Int32) {
        let azPath = self.azPath
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(String, String, Int32), Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                if azPath == "az" {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = ["az"] + args
                } else {
                    process.executableURL = URL(fileURLWithPath: azPath)
                    process.arguments = args
                }
                var env = ProcessInfo.processInfo.environment
                let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
                let existing = env["PATH"] ?? ""
                env["PATH"] = (extra + (existing.isEmpty ? [] : [existing])).joined(separator: ":")
                process.environment = env
                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: ElevationError.azLaunchFailed(error.localizedDescription))
                    return
                }
                // Drain both pipes concurrently to avoid a deadlock when one
                // fills its buffer while we block reading the other.
                var errData = Data()
                let errGroup = DispatchGroup()
                errGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    errGroup.leave()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                errGroup.wait()
                process.waitUntilExit()
                cont.resume(returning: (
                    String(data: outData, encoding: .utf8) ?? "",
                    String(data: errData, encoding: .utf8) ?? "",
                    process.terminationStatus
                ))
            }
        }
    }
}

/// Process-wide, per-domain serialization for elevation exec calls.
///
/// The elevation session container multiplexes every exec onto one pseudo-
/// terminal, so concurrent commands against the same domain corrupt each
/// other's output. A single `ElevationSession` actor is not enough to prevent
/// this — the app builds several `ElevationSession` instances (each
/// `GraphService` owns its own transport), and they all target the same shared
/// containers. This gate lives above every instance so one command runs per
/// domain at a time across the whole process. It is a fair FIFO semaphore:
/// ownership passes directly to the next waiter on release, so a domain never
/// goes idle while callers are queued.
actor ElevationSessionGate {
    static let shared = ElevationSessionGate()

    private var busy: Set<GraphDomain> = []
    private var waiters: [GraphDomain: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ domain: GraphDomain) async {
        if !busy.contains(domain) {
            busy.insert(domain)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[domain, default: []].append(continuation)
        }
    }

    func release(_ domain: GraphDomain) {
        if var queue = waiters[domain], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[domain] = queue.isEmpty ? nil : queue
            next.resume() // stays busy; ownership handed to the next waiter
        } else {
            busy.remove(domain)
        }
    }
}

public enum ElevationError: Error, CustomStringConvertible {
    case identityResolutionFailed(GraphDomain)
    case createFailed(String)
    case execHandshakeFailed(String)
    case noOutputMarkers(String)
    case corruptedOutput(expected: Int, actual: Int)
    case azLaunchFailed(String)

    /// A capture that the pty mangled — worth re-running the exec. Handshake and
    /// identity failures are not retriable here; they surface to the caller.
    var isCaptureFailure: Bool {
        switch self {
        case .noOutputMarkers, .corruptedOutput: return true
        default: return false
        }
    }

    public var description: String {
        switch self {
        case .identityResolutionFailed(let d): return "Could not resolve managed identity for domain \(d.rawValue)"
        case .createFailed(let m): return "Failed to create elevation session: \(m)"
        case .execHandshakeFailed(let m): return "Exec handshake failed: \(m)"
        case .noOutputMarkers(let t): return "Could not find output markers in session output:\n\(t)"
        case .corruptedOutput(let expected, let actual): return "Elevation output truncated by the exec bridge (expected \(expected) bytes, got \(actual))"
        case .azLaunchFailed(let m): return "Could not launch az: \(m)"
        }
    }
}
