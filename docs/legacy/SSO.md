# FleetMate SSO — Implementation Guide

## Overview

FleetMate implements Single Sign-On (SSO) for TeamDynamix (TDX) using the institution's existing SAML2/Shibboleth identity federation. After the SAML flow completes, a JWT bearer token is retrieved from the TDX API for authenticated API calls.

**Current Status:** Working on macOS with Platform SSO support (verified) and Windows (synced)

**Platform SSO:** macOS implementation supports silent authentication via Enterprise SSO Extension (Microsoft Company Portal), with automatic UPN detection from Platform SSO status and Entra ID username auto-fill. FIDO/passkey fallback with 2-second timeout handles scenarios where SSO Extension interception fails or returns errors.

---

## Authentication Flow

```
User clicks "Sign In"
        │
        ▼
WebView navigates to /TDWorkManagement/
        │
        ▼
TDX redirects to Shibboleth SP (/Shibboleth.sso/Login)
        │
        ▼
Shibboleth redirects to IdP (Microsoft Entra ID / login.microsoftonline.com)
        │
        ▼
User authenticates (password, MFA, or future: Passkey/PSSO)
        │
        ▼
Entra ID POSTs SAMLResponse to /Shibboleth.sso/SAML2/POST
        │
        ├─── macOS: Platform SSO auto-fill → SSO Extension intercepts (if in allow list)
        │         │
        │         ├─── Success: Silent token exchange → Cookies → JWT
        │         │
        │         └─── Failure: FIDO fallback → alternative auth
        │         │
        │         └─── Fallback: JS interceptor captures form, URLSession POSTs it
        │              (WKWebView strips cross-origin POST bodies)
        │
        └─── Windows: WebView2 handles cross-origin POST natively
        │
        ▼
Shibboleth validates assertion → establishes session → redirects to TDX
        │
        ▼
TDX sets session cookies, user lands on /TDWorkManagement/
        │
        ▼
FleetMate calls GET /TDWebApi/api/auth/loginSSO with session cookies
        │
        ▼
TDX returns JWT bearer token (eyJhbGciOiJIUzI1NiIs...)
        │
        ▼
JWT payload parsed for user info (given_name, email/upn)
        │
        ▼
Token stored in app state for subsequent API calls (23h expiry)
```

---

## Environment-Specific Components

### What's specific to our environment

| Component | Value | Portable? |
|-----------|-------|-----------|
| **Identity Provider** | Microsoft Entra ID (Azure AD) | Entra-specific login.microsoftonline.com URLs |
| **SP Software** | Shibboleth 3.x | Shibboleth-specific URL patterns (`/Shibboleth.sso/`) |
| **SAML Endpoint** | `/Shibboleth.sso/SAML2/POST` | Shibboleth-specific |
| **Service Provider** | servicedesk.emilycarru.ca | Institution-specific domain |
| **TDX Tenant** | `d22686a0-c1be-48e0-8f91-5bdd033f7dad` | Institution-specific |
| **BEID/WebServicesKey** | Configured per-institution | Institution-specific |

### What's generic / reusable

| Component | Notes |
|-----------|-------|
| **JWT retrieval** | `/api/auth/loginSSO` is a standard TDX endpoint |
| **JWT parsing** | Standard JWT base64url decoding |
| **WebView SSO flow** | Generic pattern — navigate, wait for success URL, extract token |
| **Success URL patterns** | `/TDWorkManagement/`, `/TDClient/`, `/TDNext/` are standard TDX paths |
| **Cookie handling** | Standard HTTP cookie management |

### Verdict

The **core flow is TDX-generic** — any TDX instance with SSO enabled should work by simply changing the base URL and credentials. The Shibboleth/Entra-specific parts are confined to the **SAML assertion interception** on macOS, which matches `Shibboleth.sso` URL patterns.

---

## Platform Differences

### macOS (WKWebView)

**Platform SSO Support (Implemented):**

FleetMate integrates with macOS Platform SSO via Enterprise SSO Extension:

1. **UPN Detection** — Runs `app-sso platform -s` on background thread to detect user's UPN from AD TGT ticket
2. **Auto-fill** — JavaScript injection fills username field on Entra sign-in page and clicks Next
3. **SSO Extension Trust** — Bundle ID `ca.ecuad.macadmin.fleetmate` matches the SSO Extension allow list prefix `ca.ecuad.macadmin.`
4. **Silent Auth** — Enterprise SSO Extension (Company Portal) intercepts login.microsoftonline.com requests for token exchange
5. **FIDO Fallback** — 2-second timeout detects FIDO prompts and error pages ("Couldn't sign you in"), clicks Back/Try again to redirect to alternative auth methods (Authenticator push, SMS, etc.)

**Bundle Configuration:**
- **Bundle ID:** `ca.ecuad.macadmin.fleetmate`
- **Team ID:** `7TF6CSP83S` (Emily Carr University of Art and Design)
- **Signing:** Developer ID Application with runtime hardening
- **Entitlements:** App sandbox disabled, network client/server enabled
- **Logging:** Unified logging via `NSLog()` for SSO flow diagnostics (visible in Console.app)

**Cross-Origin POST Fix (Fallback):**

**Problem:** Apple's WKWebView silently strips HTTP POST bodies on cross-origin form submissions. The SAML flow requires Entra ID (login.microsoftonline.com) POST the SAMLResponse to Shibboleth SP (servicedesk.emilycarru.ca/Shibboleth.sso/SAML2/POST) — a cross-origin POST. WKWebView drops the body, Shibboleth receives an empty POST, and the flow dies silently.

**Solution:** JavaScript form submission interceptor:

1. **JS injection at `atDocumentStart`** — Overrides `HTMLFormElement.prototype.submit` to detect when a form targets `Shibboleth.sso` or `SAML2/POST`
2. **WKScriptMessageHandler bridge** — Intercepted form data (SAMLResponse + RelayState) is sent to native code via `webkit.messageHandlers.samlInterceptor`
3. **URLSession POST** — Native code submits the SAML assertion via URLSession (which handles cross-origin POSTs correctly) with the WebView's cookies
4. **Cookie sync** — After URLSession completes, all cookies are synced back to the WKWebView

**Key files:**
- `Sources/FleetMateApp/Views/TdxSsoLoginView.swift` — SSO WebView, SAML interceptor, JWT retrieval
- `Sources/FleetMateCore/Services/TdxSsoService.swift` — WebView configuration, URL construction

### Windows (WebView2)

**No interception needed.** Microsoft's WebView2 (Chromium-based) handles cross-origin POST bodies correctly. The SAML flow completes naturally within the WebView.

**After success:**
1. Detect success URL pattern (`/TDWorkManagement/`, etc.)
2. Extract cookies from WebView2's CookieManager
3. Build HttpClient with those cookies
4. Call `/TDWebApi/api/auth/loginSSO` to get JWT

**Key files:**
- `FleetMate.GUI/Views/TdxSsoLoginWindow.xaml.cs` — SSO WebView2, JWT retrieval

---

## JWT Token

### Retrieval

```
GET /TDWebApi/api/auth/loginSSO
Cookie: (session cookies from SAML flow)
→ Returns: "eyJhbGciOiJIUzI1NiIs..." (quoted JSON string)
```

### Payload Claims

| Claim | Description | Example |
|-------|-------------|---------|
| `given_name` | User's first name | Rod |
| `name` | Full display name | adoe@example.edu |
| `unique_name` | Unique identifier | adoe@example.edu |
| `email` | Email address | adoe@example.edu |
| `upn` | User Principal Name | adoe@example.edu |
| `exp` | Expiry timestamp | 1738300800 |

### Usage

The JWT is used as a Bearer token for authenticated TDX API calls:
```
Authorization: Bearer eyJhbGciOiJIUzI1NiIs...
```

FleetMate sets a 23-hour expiry window and stores the token in app state.

---

## Future Plans

### Priority 1: PSSO / Passkey / Windows Hello Support

**Status:** ✅ **Working on macOS** — Platform SSO via Enterprise SSO Extension (Company Portal) is fully implemented with UPN auto-detection, auto-fill, and FIDO fallback. **Windows:** Not yet implemented.

**macOS Implementation:**
- **Platform SSO Extension:** Microsoft Company Portal (`com.microsoft.CompanyPortalMac.ssoextension`)
- **Bundle Allow List:** App bundle ID `ca.ecuad.macadmin.fleetmate` matches prefix `ca.ecuad.macadmin.` in mobileconfig
- **UPN Detection:** Runs `app-sso platform -s` on background thread to extract UPN from AD TGT ticket
- **Auto-fill:** JavaScript auto-fills username and clicks Next on Entra sign-in page (800ms render delay)
- **Silent Auth:** SSO Extension intercepts login.microsoftonline.com URLs when app is in allow list, exchanges tokens silently
- **FIDO Fallback:** 2-second timeout detects FIDO prompts and error pages, uses MutationObserver to click "Sign in another way" or "Back"/"Try again" buttons
- **Retry Logic:** Auto-fill retries at 500ms, 1s, 2s intervals; FIDO fallback retries at 100ms, 300ms, 600ms, 1s, 1.5s, 2.5s, 4s, 6s

**Windows Investigation Needed:**
- Windows Hello for Business integration via WebView2
- Web Account Manager (WAM) broker support
- FIDO2/WebAuthn platform authenticator access
- Whether WebView2 natively supports Windows Hello credentials

### Priority 2: Multi-Provider SSO

Extend beyond Shibboleth/Entra to support:
- **OIDC (OpenID Connect)** — Direct Entra/Okta/Auth0 OIDC flows
- **ADFS** — Active Directory Federation Services
- **CAS** — Central Authentication Service
- **Okta** — Okta SAML/OIDC
- **Google Workspace** — Google SAML federation

The current architecture is well-positioned for this — the success URL detection and JWT retrieval are IdP-agnostic. Only the SAML form interception (macOS) would need pattern updates to match different SP software.

### Priority 3: Token Refresh

Currently tokens expire after 23 hours and require re-authentication. Future work:
- Detect token expiry before API calls fail
- Silent re-authentication using stored session cookies
- Background token refresh

---

## Troubleshooting

### Blank screen after Microsoft login (macOS)

**Cause:** WKWebView cross-origin POST body stripping. The SAML interceptor should handle this. If it reoccurs:
1. Check Console.app for `[TdxSsoLogin]` logs
2. Verify `[SAML] Intercepted cross-origin form POST` appears
3. Check `[SAML] Response: 200` after URLSession POST
4. Verify `[JWT] ✓ Got bearer token` appears

### Token extraction fails

If SSO flow completes but no token is extracted:
1. Check that `/TDWebApi/api/auth/loginSSO` returns HTTP 200
2. Verify session cookies are being passed (check cookie sync logs)
3. The response should be a quoted JSON string containing the JWT

### Platform SSO not working (macOS)

**SSO Extension rejection (Code=-5):**

Check unified logs:
```bash
log stream --predicate 'process == "FleetMate" OR process == "com.apple.AppSSOAgent"' --level debug
```

Look for:
- `com.apple.AppSSO.AuthorizationError Code=-5` — App not in SSO Extension allow list
- `CallerTeamIdentifier = "(null)"` — App not properly signed
- `CallerTeamIdentifier = "7TF6CSP83S"` — Correct signing, check mobileconfig

**Solutions:**
1. Verify bundle ID `ca.ecuad.macadmin.fleetmate` is in Platform SSO mobileconfig `AppAllowList` or matches `AppPrefixAllowList` prefix
2. Check signing: `codesign -dv --verbose=4 /path/to/FleetMate.app | grep TeamIdentifier`
3. Verify SSO Extension profile is installed: `profiles show -type configuration`
4. Reinstall Platform SSO mobileconfig if `AppAllowList` was updated
5. Check Console.app for `[TdxSsoLogin]` entries

**UPN not detected:**

Check if Platform SSO is active:
```bash
app-sso platform -s
```

Should show AD TGT ticket with UPN (e.g., `adoe@EXAMPLE.EDU`). If empty, user may need to sign out and back in to macOS to establish Platform SSO credentials.

**Auto-fill not triggering:**

Check Console.app logs for `[TdxSsoLogin]` entries. Should see:
- `✓ Detected Platform SSO UPN: user@domain`
- `[Entra] Status: Injecting auto-fill script`
- `[Entra] Auto-fill script executed`

If UPN is detected but auto-fill doesn't work:
1. The username field selector may have changed — check `input[name="loginfmt"]`
2. React change events may not be triggering — verify `new Event('input', {bubbles: true})`
3. Next button selector may have changed — check `.button_primary` selector

### SSO URL not triggering redirect

If the WebView shows the TDX page without redirecting to the IdP:
1. Verify `TDX_BASE_URL` is set correctly (e.g., `https://servicedesk.emilycarru.ca/TDWebApi`)
2. The SSO entry URL should be `{root}/TDWorkManagement/` (not `/api/auth/loginsso`)
3. Check that SSO is enabled for the TDX instance

---

## Configuration

### Required Settings

| Setting | Description | Example |
|---------|-------------|---------|
| `TDX_BASE_URL` | TDX API base URL | `https://servicedesk.emilycarru.ca/TDWebApi` |
| `TDX_APP_ID` | TDX application ID | `631` |

### Optional (for API auth fallback)

| Setting | Description |
|---------|-------------|
| `TDX_BEID` | BEID for admin auth |
| `TDX_WEB_SERVICES_KEY` | Web services key |
| `TDX_USERNAME` / `TDX_PASSWORD` | Username/password auth |

SSO is attempted when `TDX_BASE_URL` is configured. It runs alongside (not replacing) API key authentication — SSO provides user-context actions (commenting as yourself), while API keys provide service-level access.
