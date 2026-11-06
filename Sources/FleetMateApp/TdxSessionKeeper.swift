import AppKit
import Network
import FleetMateCore

/// Keeps the TeamDynamix session alive in both processes — the app window
/// and the background inbox helper.
///
/// The two share one session through the keychain. Each renews before
/// expiry, but first checks whether the other already has, and a file lock
/// stops both running the sign-in chain at once: one renews, the other
/// reloads. A failed silent sign-in is retried on a backoff (1, 5, 15
/// minutes, then every 15), and again straight away on wake, unlock or a
/// network change. Once it keeps failing with no session left, the app shows
/// a sign-in banner instead of failing every call.
extension AppState {
    static let tdxRenewal = TdxRenewalSchedule.standard

    func makeTdxService(config: FleetMateConfig) -> TdxService {
        let service = TdxService(config: config)
        guard Self.isTdxSessionCacheEnabled else { return service }
        service.sharedSessionLoader = { TdxSessionCache.load() }
        service.sharedSessionUpn = TdxSsoLoginViewModel.fallbackUpn
        service.onSharedSessionAdopted = { [weak self] cached in
            Task { @MainActor in self?.adoptSharedTdxSession(cached) }
        }
        return service
    }

    /// The real expiry of a TeamDynamix JWT, capped at the 23 hours the app
    /// has always assumed; 23 hours for a cookie session.
    static func tdxSessionExpiry(for token: String, now: Date = Date()) -> Date {
        let assumed = now.addingTimeInterval(23 * 60 * 60)
        guard let expiry = TdxSessionCache.jwtExpiry(token) else { return assumed }
        return min(expiry, assumed)
    }

    /// The other process saved a newer session and this one took it.
    private func adoptSharedTdxSession(_ cached: TdxSessionCache) {
        tdxSsoAuthenticated = true
        tdxAuthenticatedUserName = cached.userName
        tdxRenewalFailures = 0
        tdxNeedsSignIn = false
        authManager.update(.tdx, state: .valid(user: cached.userName, expiry: cached.expiry))
        if tdxMe == nil, let me = cached.confirmedMe {
            tdxMe = me
            ticketInbox.start(service: tdxService, me: me)
        }
        guard !InboxAgent.isAgentProcess else { return }
        if !isTicketsCacheValid {
            Task { await preloadTickets() }
        }
    }

    /// Every silent sign-in ends here, whichever route it took.
    func finishTdxSignIn(succeeded: Bool) {
        if succeeded {
            tdxRenewalFailures = 0
            tdxNeedsSignIn = false
        } else if tdxSignInInFlight {
            tdxRenewalFailures += 1
        }
        if tdxSignInInFlight { tdxLastRenewalAttempt = Date() }
        tdxSignInInFlight = false
        let waiters = tdxSignInWaiters
        tdxSignInWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: succeeded) }
        refreshTdxSessionStatus()
    }

    /// Run a fresh silent sign-in, or wait for the one already running.
    private func renewTdxSessionSilently() async -> Bool {
        if !tdxSignInInFlight {
            attemptSilentTdxSso(useCache: false)
            guard tdxSignInInFlight else { return tdxService.hasUsableUserSession() }
        }
        return await withCheckedContinuation { tdxSignInWaiters.append($0) }
    }

    /// Bring the row and the banner in line with the session actually held:
    /// a probe's Valid does not outlive the token it checked.
    func refreshTdxSessionStatus(now: Date = Date()) {
        let usable = tdxService.hasUsableUserSession(now: now)
        if !usable, case .valid = authManager.systems[.tdx]?.state, !tdxHasServiceAccount {
            authManager.update(.tdx, state: .expired)
            tdxSsoAuthenticated = false
        }
        let needs = tdxService.refusedSsoReason != nil
            || Self.tdxRenewal.needsInteractiveSignIn(expiry: tdxService.userSessionExpiry,
                                                     failures: tdxRenewalFailures, now: now)
        if needs != tdxNeedsSignIn { tdxNeedsSignIn = needs }
    }

    var tdxHasServiceAccount: Bool {
        config.tdxAuthMethod != .browserSSO && (config.tdxBeid != nil || config.tdxUsername != nil)
    }

    /// The interactive sign-in the banner and the panel's Sign In button
    /// open. Only ever on the person's request, never by itself.
    func signInToTdxInteractively() {
        guard !InboxAgent.isAgentProcess, config.isTdxConfigured else { return }
        showTdxSsoLogin = true
    }

    /// The interactive sheet finished.
    func handleInteractiveTdxResult(_ result: TdxSsoResult) {
        if result.isIdentityRefused {
            rejectTdxSsoIdentity(result)
        } else if result.success, let token = result.token, !token.isEmpty {
            handleTdxSsoSuccess(token: token, expiry: Self.tdxSessionExpiry(for: token),
                                userId: result.userEmail, userName: result.userName)
        } else {
            handleTdxSsoFailure(result.error)
        }
    }

    // MARK: - Renewal loop

    /// Start keeping the session alive. Safe to call more than once.
    func startTdxRenewal() {
        guard tdxRenewalTask == nil, config.isTdxConfigured, tdxService.shouldAttemptSso else { return }
        observeTdxRenewalTriggers()
        tdxRenewalTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tdxRenewalTick()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func tdxRenewalTick() async {
        let now = Date()
        // Pick up the other process's renewal before deciding to renew.
        tdxService.reloadSharedSession(now: now)
        refreshTdxSessionStatus(now: now)
        guard !tdxSignInInFlight, tdxService.refusedSsoReason == nil else { return }

        let expiry = tdxService.userSessionExpiry
        let kicked = tdxRenewalKick && !Self.tdxRenewal.isUsable(expiry: expiry, now: now)
        tdxRenewalKick = false
        let due = Self.tdxRenewal.nextAttempt(expiry: expiry, failures: tdxRenewalFailures,
                                              lastAttempt: tdxLastRenewalAttempt, now: now)
        guard kicked || due <= now else { return }

        dbg.info("TDX renewal due (failures=\(tdxRenewalFailures), expires in \(expiry.map { Int($0.timeIntervalSince(now)) } ?? 0)s)", category: "tdx-auth")
        let outcome = await TdxSessionSync.withRenewalLock { await self.renewTdxSessionSilently() }
        if outcome == nil {
            // The other process is signing in; take its session when it lands.
            dbg.info("TDX renewal skipped: the other process is renewing", category: "tdx-auth")
            try? await Task.sleep(for: .seconds(60))
            tdxService.reloadSharedSession(force: true)
            refreshTdxSessionStatus()
        } else if outcome == false {
            let wait = Self.tdxRenewal.retryDelay(afterFailures: tdxRenewalFailures)
            dbg.warn("TDX silent renewal failed (\(tdxRenewalFailures) in a row); next try in \(Int(wait))s", category: "tdx-auth")
        }
    }

    private func observeTdxRenewalTriggers() {
        let kick: (Notification) -> Void = { [weak self] note in
            Task { @MainActor in
                dbg.info("TDX renewal check after \(note.name.rawValue)", category: "tdx-auth")
                self?.tdxRenewalKick = true
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        tdxRenewalObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: kick))
        tdxRenewalObservers.append(workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main, using: kick))

        let distributed = DistributedNotificationCenter.default()
        tdxRenewalObservers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: kick))
        tdxRenewalObservers.append(distributed.addObserver(forName: TdxSessionSync.changedNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.object as? String) != TdxSessionSync.senderId else { return }
            Task { @MainActor in
                guard let self else { return }
                if self.tdxService.reloadSharedSession(force: true) {
                    dbg.info("TDX session reloaded after the other process saved it", category: "tdx-auth")
                }
            }
        })

        let monitor = NWPathMonitor()
        let last = PathState()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            defer { last.satisfied = satisfied }
            guard satisfied, !last.satisfied else { return }
            Task { @MainActor in
                dbg.info("TDX renewal check after the network came back", category: "tdx-auth")
                self?.tdxRenewalKick = true
            }
        }
        monitor.start(queue: DispatchQueue(label: "tdx-renewal.network"))
        tdxPathMonitor = monitor
    }
}

/// The last network state, touched only on the monitor's serial queue.
private final class PathState: @unchecked Sendable {
    var satisfied = true
}
