import Foundation
import FleetMateCore

extension TdxService {
    /// Sign in as the person at the keyboard before any TDX call, the same
    /// silent way the app does. Without this the CLI only ever had the service
    /// account, so it failed outright on a machine with none configured.
    ///
    /// Shows nothing and asks nothing. Failure refuses all credential fallback
    /// so the command cannot silently run as a different identity.
    @MainActor
    func signInSilently(config: FleetMateConfig) async {
        guard isConfigured, shouldAttemptSso, !actingIdentityIsUser else { return }

        let upn = LoginCommand.account(LoginCommand.locateAz())?.user
            ?? SignedInAddress.readDevice()?.address

        if let cached = TdxCliSessionCache.read(baseURL: baseUrl, expectedUpn: upn) {
            dbg.debug("TDX CLI using its verified Keychain session", category: "tdx-sso")
            TdxHeadlessSignIn.apply(cached, to: self, config: config)
            return
        }

        guard let result = await TdxHeadlessSignIn.run(config: config, upn: upn) else {
            dbg.warn("TDX silent sign-in failed in the CLI", category: "tdx-sso")
            refuseSso(reason: "Silent TeamDynamix sign-in failed. The command was not run.")
            return
        }
        if result.isIdentityRefused {
            refuseSso(reason: result.error ?? "TDX sign-in refused: identity could not be confirmed")
            return
        }
        TdxHeadlessSignIn.apply(result, to: self, config: config)
        if actingIdentityIsUser { TdxCliSessionCache.save(result, baseURL: baseUrl, expectedUpn: upn) }
    }
}
