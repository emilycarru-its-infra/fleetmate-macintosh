# Plan: FleetMate Module & SSO Dependency Audit

**TL;DR:** Only 2 of 10 modules work with SSO alone (Azure DevOps, TDX in BrowserSSO mode). The rest require service principal secrets, API keys, or passphrases that must come from Azure Key Vault via the setup script. The #1 reason things break on a fresh install is the setup script either wasn't run, or `az` CLI ends up logged in as a Service Principal afterwards.

---

## Module Readiness Matrix

| # | Module (Tab) | Auth Method | Works with SSO alone? | Required Secrets | External Tools |
|---|-------------|------------|----------------------|-----------------|----------------|
| 1 | **Devices** (Intune) | Graph client_credentials (SP) | **No** — needs SP secrets | `graph_tenant_id`, `devices_graph_id`, `devices_graph_secret` | — |
| 2 | **Identity** (Users/Groups) | Graph client_credentials (separate SP) | **No** — needs SP secrets | `graph_tenant_id`, `systems_graph_id`, `systems_graph_secret` | — |
| 3 | **Inventory** (Snipe-IT) | API key | **No** — needs API key | `snipe_url`, `snipe_api_key` | — |
| 4 | **Tickets** (TDX) | SAML SSO **or** ServiceAccount **or** UserPassword | **Yes** — if `tdx_auth_method: BrowserSSO` | `tdx_base_url`, `tdx_app_id` (minimum). For fallback: `tdx_beid` + `tdx_web_services_key` OR `tdx_username` + `tdx_password` | — |
| 5 | **Projects** (Azure DevOps) | OAuth2 PKCE (SSO only, no PAT) | **Yes** — only needs org name + user login | `devops_organization` | `az` CLI (strongly recommended for silent token) |
| 6 | **Projects** (GitHub) | gh CLI token / PAT / Device Flow | **Yes** — if `gh` CLI authenticated | `tasks.providers.github.enabled: true`, `.owner`, `.project_number` | `gh` CLI |
| 7 | **Projects** (Gitea) | API token | **No** — needs token | `tasks.providers.gitea.url`, `.token` | — |
| 8 | **Reporting** (ReportMate) | Passphrase header | **No** — needs passphrase | `reportmate_url`, `reportmate_passphrase` | — |
| 9 | **SSH** (Remote exec) | SSH key | **No** — needs SSH key | `secure_shell.privateKeyPath` or env var | `ssh` |
| 10 | **Planner Sync** | az CLI SSO | **Yes** — if az logged in as user | `tasks.planner.plan_id` | `az` CLI |

---

## Secrets Inventory (from Azure Key Vault)

All secrets are fetched by `scripts/setup-secrets.sh` (macOS) / `scripts/setup-secrets.ps1` (Windows) from **3 Key Vaults**:

| Secret | YAML Key | Env Var | Key Vault | Module |
|--------|----------|---------|-----------|--------|
| Snipe URL | `snipe_url` | `SNIPE_URL` | `assets-inventory-creds` | Inventory |
| Snipe API Key | `snipe_api_key` | `SNIPE_API_KEY` | `assets-inventory-creds` | Inventory |
| Tenant ID | `graph_tenant_id` | `GRAPH_TENANT_ID` | `assets-inventory-creds` | Devices, Identity |
| Devices SP Client ID | `devices_graph_id` | `GRAPH_CLIENT_ID` | `entra-devops-secrets` | Devices |
| Devices SP Client Secret | `devices_graph_secret` | `GRAPH_CLIENT_SECRET` | `entra-devops-secrets` | Devices |
| Systems SP Client ID | `systems_graph_id` | — | `entra-devops-secrets` | Identity |
| Systems SP Client Secret | `systems_graph_secret` | — | `entra-devops-secrets` | Identity |
| DevOps Org | `devops_organization` | `DEVOPS_ORGANIZATION` | `cimian-repo-secrets` | Projects (DevOps) |
| DevOps Project | `devops_project` | `DEVOPS_PROJECT` | `cimian-repo-secrets` | Projects (DevOps) |
| TDX Username | `tdx_username` | `TDX_USERNAME` | `assets-inventory-creds` | Tickets (fallback) |
| TDX Password | `tdx_password` | `TDX_PASSWORD` | `assets-inventory-creds` | Tickets (fallback) |
| TDX BEID | `tdx_beid` | `TDX_BEID` | `assets-inventory-creds` | Tickets (admin) |
| TDX Web Services Key | `tdx_web_services_key` | `TDX_WEB_SERVICES_KEY` | `assets-inventory-creds` | Tickets (admin) |
| ReportMate URL | `reportmate_url` | `REPORTMATE_URL` | `cimian-repo-secrets` | Reporting |
| ReportMate Passphrase | `reportmate_passphrase` | `REPORTMATE_PASSPHRASE` | `cimian-repo-secrets` | Reporting |

**NOT in any Key Vault** (must be set manually or are hardcoded in the setup script):
- `tdx_base_url` → hardcoded to `https://servicedesk.emilycarru.ca/TDWebApi` in setup script
- `tdx_app_id` → hardcoded to `116` in setup script
- `tdx_ticketing_app_id`, `tdx_assets_app_id` → not set anywhere by setup scripts

---

## Why Most Things Broke on a Fresh Laptop

1. **Setup script not run or Key Vault access denied** → `secrets.yaml` empty → Devices, Identity, Inventory, Tickets (non-SSO), Reporting all fail their `isConfigured` checks
2. **`az` CLI logged in as Service Principal** after running `setup-secrets.sh` → DevOps SSO silently fails (SP can't do PKCE user auth)
3. **`tdx_ticketing_app_id` / `tdx_assets_app_id` never populated** → TDX ticket/asset operations may fail even with valid JWT
4. **GitHub provider disabled by default** (`enabled: false`) → Projects tab shows nothing for GitHub
5. **No `config.sample.yaml` for macOS** → no reference for what keys to put in `~/.fleetmate/config.yaml`

---

## Recommended Steps

### Phase 1 — Document (add to `IMPLEMENTATION.md` or new `SETUP.md`)

1. Add the module readiness matrix and secrets inventory tables above as a permanent reference
2. Document the "fresh laptop" setup checklist with verification for each step

### Phase 2 — Fix config gaps

3. Add missing keys to `config.sample.yaml` (`tdx_base_url`, `tdx_app_id`, `tdx_ticketing_app_id`, `tdx_assets_app_id`)
4. Create a macOS `config.sample.yaml` (or symlink the Windows one) so macOS users have a starting template
5. Add a post-setup warning in `setup-secrets.sh` telling the user to run `az login` (interactive) after the script completes, since the script may leave `az` in SP mode

### Phase 3 — Add system-check for macOS

6. Port `fleetmate-windows/scripts/system-check.ps1` to a macOS `scripts/system-check.sh` that validates:
   - Config/secrets files exist
   - Each module's `isConfigured` equivalent passes
   - `az` / `gh` / `ssh` are installed
   - `az account show` returns a user principal (not an SP)
   - Reports a per-module GO/NO-GO status

## Verification

1. Run `setup-secrets.sh --force` on fresh machine → confirm `secrets.yaml` has all 15+ keys populated
2. Run `system-check.sh` → confirm it correctly identifies which modules are ready
3. With only `tdx_base_url` + `tdx_app_id` set and BrowserSSO mode → confirm Tickets tab works via SSO
4. With only `devops_organization` set and `az login` (user) → confirm Projects tab works via SSO
