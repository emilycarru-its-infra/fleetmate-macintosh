#!/bin/bash
# =============================================================================
# FleetMate macOS - Secure Secrets Setup
# =============================================================================
# This script retrieves secrets from Azure Key Vault and stores them securely
# in the macOS Keychain - NOT in plain text files.
#
# Can be run manually: ./scripts/setup-secrets.sh [--force]
#
# Prerequisites:
#   - Azure CLI installed (brew install azure-cli)
#   - Access to the Azure subscription and Key Vault
#   - Membership in the DevOps resources owners group (or Key Vault RBAC)
#
# Security:
#   - Secrets are stored in macOS Keychain, not plain text files
#   - Uses Azure CLI SSO for authentication
#   - Config file only contains non-sensitive settings
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Azure Key Vault Configuration
KEY_VAULT_NAME="assets-inventory-creds"
CIMIAN_KEY_VAULT_NAME="cimian-repo-secrets"
ENTRA_KEY_VAULT_NAME="entra-devops-secrets"
SUBSCRIPTION_ID="59d35012-b593-4b2f-bd50-28e666ed12f7"
TENANT_ID="d22686a0-c1be-48e0-8f91-5bdd033f7dad"

# Config file (non-sensitive settings only)
CONFIG_DIR="$HOME/.fleetmate"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
SECRETS_FILE="$CONFIG_DIR/secrets.yaml"

# Check if running with --force flag
FORCE_RUN=false
[[ "$1" == "--force" || "$1" == "-f" ]] && FORCE_RUN=true

# Check if already configured (unless forced)
if [[ "$FORCE_RUN" != "true" ]]; then
    # Check if secrets file exists and has content
    if [ -f "$SECRETS_FILE" ] && grep -q "snipe_api_key:" "$SECRETS_FILE" 2>/dev/null; then
        echo "FleetMate secrets already configured in: $SECRETS_FILE"
        echo "Run with --force to refresh: $0 --force"
        exit 0
    fi
fi

echo ""
echo "======================================================================"
echo "  FleetMate macOS - Secure Secrets Setup"
echo "======================================================================"
echo ""
echo "This script will:"
echo "  1. Authenticate to Azure using SSO"
echo "  2. Fetch secrets from Azure Key Vault"
echo "  3. Store them in ~/.fleetmate/secrets.yaml (0600 permissions)"
echo "  4. Create a config file for non-sensitive settings"
echo ""

# Check if Azure CLI is installed
if ! command -v az &> /dev/null; then
    echo "❌ Error: Azure CLI is not installed."
    echo ""
    echo "Install it with: brew install azure-cli"
    echo "Then run: $0"
    exit 1
fi

# Check current login status and login if needed
echo "🔐 Checking Azure CLI login status..."
if ! az account show &> /dev/null; then
    echo "   Not logged in. Initiating SSO login..."
    if ! az login --tenant "$TENANT_ID"; then
        echo "❌ Login failed."
        exit 1
    fi
else
    CURRENT_TENANT=$(az account show --query "tenantId" -o tsv)
    if [ "$CURRENT_TENANT" != "$TENANT_ID" ]; then
        echo "   Logged into different tenant. Switching..."
        if ! az login --tenant "$TENANT_ID"; then
            echo "❌ Login failed."
            exit 1
        fi
    else
        echo "   ✓ Already logged in to correct tenant."
    fi
fi

# Set the subscription
az account set --subscription "$SUBSCRIPTION_ID" 2>/dev/null
SUBSCRIPTION_NAME=$(az account show --query "name" -o tsv)
echo "   ✓ Subscription: $SUBSCRIPTION_NAME"
echo ""

# Function to get secret from Key Vault
get_secret() {
    local vault="$1"
    local name="$2"
    az keyvault secret show --vault-name "$vault" --name "$name" --query "value" -o tsv 2>/dev/null || echo ""
}

echo "📦 Fetching secrets from Azure Key Vault..."
echo ""

# Fetch secrets from Inventory Key Vault
echo "   From Key Vault: $KEY_VAULT_NAME"
echo "   ├─ SnipeApiUrl..."
SNIPE_API_URL=$(get_secret "$KEY_VAULT_NAME" "SnipeApiUrl")
echo "   ├─ SnipeApiKey..."
SNIPE_API_KEY=$(get_secret "$KEY_VAULT_NAME" "SnipeApiKey")
echo "   ├─ TdxUsername..."
TDX_USERNAME=$(get_secret "$KEY_VAULT_NAME" "TdxUsername")
echo "   ├─ TdxPassword..."
TDX_PASSWORD=$(get_secret "$KEY_VAULT_NAME" "TdxPassword")
echo "   ├─ TdxBeid..."
TDX_BEID=$(get_secret "$KEY_VAULT_NAME" "TdxBeid")
echo "   └─ TdxBeidSecret..."
TDX_WEB_SERVICES_KEY=$(get_secret "$KEY_VAULT_NAME" "TdxBeidSecret")

# Fetch secrets from Cimian Key Vault
echo ""
echo "   From Key Vault: $CIMIAN_KEY_VAULT_NAME"
echo "   ├─ ReportMateApiUrl..."
REPORTMATE_URL=$(get_secret "$CIMIAN_KEY_VAULT_NAME" "ReportMateApiUrl")
echo "   ├─ ReportMatePassphrase..."
REPORTMATE_PASSPHRASE=$(get_secret "$CIMIAN_KEY_VAULT_NAME" "ReportMatePassphrase")
echo "   ├─ AzureDevOpsOrganization..."
DEVOPS_ORG=$(get_secret "$CIMIAN_KEY_VAULT_NAME" "AzureDevOpsOrganization")
echo "   └─ AzureDevOpsProject..."
DEVOPS_PROJECT=$(get_secret "$CIMIAN_KEY_VAULT_NAME" "AzureDevOpsProject")

# Graph credentials are no longer fetched or stored locally. FleetMate reaches
# Microsoft Graph through the `aze` elevation model (GraphService default), where
# the DevOps-Devices / DevOps-Identity managed-identity token is minted inside an
# ephemeral Azure Container Instance and never touches this machine. The break-glass
# `direct` transport (FLEETMATE_GRAPH_TRANSPORT=direct) uses a delegated token from
# the operator's own `az login`, not a service-principal secret.

echo ""

# Set defaults for missing values
REPORTMATE_URL="${REPORTMATE_URL:-https://reportmate-functions-api.blackdune-79551938.canadacentral.azurecontainerapps.io}"
DEVOPS_ORG="${DEVOPS_ORG:-ecuad}"
DEVOPS_PROJECT="${DEVOPS_PROJECT:-DevOps}"

# Validate required secrets
MISSING_SECRETS=()
[ -z "$SNIPE_API_KEY" ] && MISSING_SECRETS+=("SnipeApiKey")

if [ ${#MISSING_SECRETS[@]} -gt 0 ]; then
    echo "⚠️  Warning: The following secrets are missing from Key Vault:"
    for secret in "${MISSING_SECRETS[@]}"; do
        echo "      - $secret"
    done
    echo ""
    echo "   Some features may not work without these secrets."
    echo ""
fi

# Create config directory first
mkdir -p "$CONFIG_DIR"

# Create secrets.yaml with sensitive credentials (readable by app without prompts)
# This is the PRIMARY secret storage - no Keychain prompts!
SECRETS_FILE="$CONFIG_DIR/secrets.yaml"
echo "📝 Creating secrets file (protected, 0600 permissions)..."
cat > "$SECRETS_FILE" << EOF
# FleetMate Secrets (AUTO-GENERATED - DO NOT EDIT)
# Refreshed from Azure Key Vault by scripts/setup-secrets.sh
# Permissions: 0600 (owner read/write only)

# Snipe-IT
snipe_url: "${SNIPE_API_URL:-}"
snipe_api_key: "${SNIPE_API_KEY:-}"

# Microsoft Graph credentials intentionally omitted — FleetMate authenticates to
# Graph via the aze elevation model (no service-principal secret on this machine).

# Azure DevOps (uses 'az' CLI with user login)
devops_organization: "${DEVOPS_ORG:-}"
devops_project: "${DEVOPS_PROJECT:-}"

# TeamDynamix
tdx_base_url: "https://servicedesk.emilycarru.ca/TDWebApi"
tdx_app_id: 116
tdx_username: "${TDX_USERNAME:-}"
tdx_password: "${TDX_PASSWORD:-}"
tdx_beid: "${TDX_BEID:-}"
tdx_web_services_key: "${TDX_WEB_SERVICES_KEY:-}"

# ReportMate
reportmate_url: "${REPORTMATE_URL:-}"
reportmate_passphrase: "${REPORTMATE_PASSPHRASE:-}"
EOF
chmod 600 "$SECRETS_FILE"
echo "   ✓ Created: $SECRETS_FILE (permissions: 0600)"
echo ""

# Count configured secrets
STORED=0
[ -n "$SNIPE_API_URL" ] && ((STORED++))
[ -n "$SNIPE_API_KEY" ] && ((STORED++))
[ -n "$DEVOPS_ORG" ] && ((STORED++))
[ -n "$DEVOPS_PROJECT" ] && ((STORED++))
[ -n "$TDX_USERNAME" ] && ((STORED++))
[ -n "$TDX_PASSWORD" ] && ((STORED++))
[ -n "$TDX_BEID" ] && ((STORED++))
[ -n "$TDX_WEB_SERVICES_KEY" ] && ((STORED++))
[ -n "$REPORTMATE_URL" ] && ((STORED++))
[ -n "$REPORTMATE_PASSPHRASE" ] && ((STORED++))
STORED=$((STORED + 2))  # TdxBaseUrl and TdxAppId are always set

echo ""

# Generate config.yaml with NON-SENSITIVE settings only
echo "📝 Creating config file (non-sensitive settings only)..."
cat > "$CONFIG_FILE" << 'EOF'
# FleetMate Configuration
# ========================
# Sensitive credentials are stored in macOS Keychain, not here.
# Run 'scripts/setup-secrets.sh --force' to refresh secrets from Azure Key Vault.

# Graph API (Microsoft Intune/Entra)
# Credentials: Keychain -> ca.ecuad.macadmin.fleetmate -> GraphClientId, GraphClientSecret, GraphTenantId
graph:
  use_azure_cli_auth: true  # Prefer Azure CLI SSO over client credentials

# Snipe-IT Asset Management
# Credentials: Keychain -> ca.ecuad.macadmin.fleetmate -> SnipeApiKey, SnipeUrl
snipe:
  enabled: true

# TeamDynamix (TDX) Ticketing
# Credentials: Keychain -> ca.ecuad.macadmin.fleetmate -> TdxUsername, TdxPassword, TdxBeid, TdxWebServicesKey
tdx:
  base_url: https://servicedesk.emilycarru.ca/TDWebApi
  app_id: 116
  enabled: true

# Azure DevOps (Work Items)
# Uses Azure CLI SSO for authentication
devops:
  enabled: true
  use_azure_cli_auth: true

# ReportMate API
# Credentials: Keychain -> ca.ecuad.macadmin.fleetmate -> ReportMateUrl, ReportMatePassphrase
reportmate:
  enabled: true

# Secure Shell (SSH)
secure_shell:
  private_key_path: ~/.ssh/id_rsa
  default_username: winadmins
  connection_timeout_seconds: 30
  command_timeout_seconds: 120
  max_concurrent_connections: 10
  port: 22

# MunkiReport (macOS fleet reporting)
munki_report:
  enabled: false
  hosts: []

# Task Provider Settings
tasks:
  default_provider: azdevops
  providers:
    azdevops:
      enabled: true
    github:
      enabled: false
    gitea:
      enabled: false

# Logging
log_level: info
EOF

echo "   ✓ Created: $CONFIG_FILE"
echo ""

# Create a helper script to view configured secrets (shows which ones are set, not values)
HELPER_SCRIPT="$CONFIG_DIR/check-secrets.sh"
cat > "$HELPER_SCRIPT" << 'EOF'
#!/bin/bash
# Check which FleetMate secrets are configured

SECRETS_FILE="$HOME/.fleetmate/secrets.yaml"

echo ""
echo "FleetMate Secrets Status"
echo "========================"
echo ""

if [ ! -f "$SECRETS_FILE" ]; then
    echo "  ✗ Secrets file not found: $SECRETS_FILE"
    echo ""
    echo "Run scripts/setup-secrets.sh to configure secrets."
    exit 1
fi

echo "Secrets file: $SECRETS_FILE"
echo "Permissions: $(stat -f '%Sp' "$SECRETS_FILE")"
echo ""

check_secret() {
    local key="$1"
    local value=$(grep "^${key}:" "$SECRETS_FILE" 2>/dev/null | cut -d'"' -f2)
    if [ -n "$value" ] && [ "$value" != "" ]; then
        echo "  ✓ $key"
    else
        echo "  ✗ $key (not set)"
    fi
}

check_secret "snipe_url"
check_secret "snipe_api_key"
check_secret "tdx_base_url"
check_secret "tdx_username"
check_secret "tdx_password"
check_secret "tdx_beid"
check_secret "tdx_web_services_key"
check_secret "reportmate_url"
check_secret "reportmate_passphrase"
check_secret "devops_organization"
check_secret "devops_project"

echo ""
echo "To refresh: scripts/setup-secrets.sh --force"
echo ""
EOF
chmod +x "$HELPER_SCRIPT"

echo "======================================================================"
echo "  ✅ Setup Complete!"
echo "======================================================================"
echo ""
echo "Stored $STORED secrets in: $SECRETS_FILE"
echo ""
echo "Files created:"
echo "  - $SECRETS_FILE (credentials, 0600 permissions)"
echo "  - $CONFIG_FILE (non-sensitive settings)"
echo "  - $HELPER_SCRIPT (check secret status)"
echo ""
echo "To refresh secrets from Azure Key Vault:"
echo "  $0 --force"
echo ""
echo "To check which secrets are configured:"
echo "  $HELPER_SCRIPT"
echo ""
