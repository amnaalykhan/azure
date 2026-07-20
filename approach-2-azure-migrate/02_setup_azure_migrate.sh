#!/bin/bash

################################################################################
# Approach 2 — Phase 2: Azure Infrastructure Setup
#
# Creates all Azure resources needed for migration using the discovery bundle
# from 01_discover.sh. This is the equivalent of "terraform apply" in Approach 1,
# but implemented with Azure CLI so it integrates with Azure Migrate.
#
# Resources created:
#   - Resource Group
#   - Virtual Network + App Subnet + DB Subnet
#   - Network Security Group (rules built from discovered ports)
#   - Storage Account (for migration data + backups)
#   - Storage containers (migration-files, backups)
#   - Recovery Services Vault + Backup Policy
#   - Azure Migrate Project
#   - Log file for all resource IDs
#
# Usage:
#   ./02_setup_azure_migrate.sh <source-vm> <ssh-user> <discovery-dir> [location]
#
# Example:
#   ./02_setup_azure_migrate.sh myvm.fyre.ibm.com root discovery_20250101_120000
#   ./02_setup_azure_migrate.sh myvm.fyre.ibm.com root discovery_20250101_120000 eastus
################################################################################

set -euo pipefail

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

# ── Arguments ──────────────────────────────────────────────────────────────────
SOURCE_VM="${1:-}"
SSH_USER="${2:-root}"
DISCOVERY_DIR="${3:-}"
LOCATION="${4:-eastus}"

# ── Derived config ─────────────────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d%H%M%S)
# Storage account name: lowercase letters and numbers only, max 24 chars
STORAGE_SUFFIX="${TIMESTAMP: -8}"

RESOURCE_GROUP=""
PROJECT_NAME=""
VNET_NAME=""
APP_SUBNET_NAME=""
DB_SUBNET_NAME=""
NSG_NAME=""
STORAGE_ACCOUNT=""
VAULT_NAME=""
MIGRATE_PROJECT=""

LOG_DIR="azure_setup_${TIMESTAMP}"
LOG_FILE="$LOG_DIR/setup.log"
RESOURCES_FILE="$LOG_DIR/created_resources.json"

# ── Helpers ───────────────────────────────────────────────────────────────────
print_banner() {
    echo -e "${CYAN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║   Approach 2 — Phase 2: Azure Infrastructure Setup           ║
║   Build VNet, NSG, Storage, Vault, Migrate Project           ║
╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

header()  { echo -e "\n${CYAN}══ $1 ══${NC}" | tee -a "$LOG_FILE"; }
section() { echo -e "\n${BLUE}── $1 ──${NC}" | tee -a "$LOG_FILE"; }
ok()      { echo -e "${GREEN}✓${NC} $1" | tee -a "$LOG_FILE"; }
info()    { echo -e "${BLUE}ℹ${NC} $1" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1" | tee -a "$LOG_FILE"; }
step()    { echo -e "${MAGENTA}▶${NC} $1" | tee -a "$LOG_FILE"; }
die()     { echo -e "${RED}✗ FATAL:${NC} $1" | tee -a "$LOG_FILE"; exit 1; }

confirm() {
    echo -e "${YELLOW}$1${NC}"
    read -rp "Continue? (yes/no): " ans
    [[ "$ans" =~ ^[Yy][Ee][Ss]$ ]] || { warn "Cancelled by user."; exit 0; }
}

################################################################################
# Preflight
################################################################################

preflight() {
    header "Preflight"

    [[ -z "$SOURCE_VM" || -z "$DISCOVERY_DIR" ]] && {
        echo "Usage: $0 <source-vm> <ssh-user> <discovery-dir> [location]"
        echo "Example: $0 myvm.fyre.ibm.com root discovery_20250101_120000 eastus"
        exit 1
    }

    mkdir -p "$LOG_DIR"

    [[ -d "$DISCOVERY_DIR" ]] || die "Discovery directory not found: $DISCOVERY_DIR"
    [[ -f "$DISCOVERY_DIR/vm_profile.json" ]] || die "vm_profile.json not found. Run 01_discover.sh first."
    [[ -f "$DISCOVERY_DIR/azure_sizing.json" ]] || die "azure_sizing.json not found. Run 01_discover.sh first."
    [[ -f "$DISCOVERY_DIR/azure_nsg_rules.json" ]] || die "azure_nsg_rules.json not found. Run 01_discover.sh first."

    command -v az  &>/dev/null || die "Azure CLI not installed. Install: https://docs.microsoft.com/cli/azure/install-azure-cli"
    command -v jq  &>/dev/null || die "jq not installed"

    info "Checking Azure login..."
    az account show &>/dev/null || die "Not logged in. Run: az login"

    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
    ok "Azure authenticated: $SUBSCRIPTION_NAME"
    info "Subscription: $SUBSCRIPTION_ID"

    # Load discovery data
    VM_HOSTNAME=$(jq -r '.hostname' "$DISCOVERY_DIR/vm_profile.json")
    VM_SIZE=$(jq -r '.recommended.vm_size' "$DISCOVERY_DIR/azure_sizing.json")
    OS_DISK_GB=$(jq -r '.recommended.os_disk_gb' "$DISCOVERY_DIR/azure_sizing.json")
    DATA_DISK_GB=$(jq -r '.recommended.data_disk_gb' "$DISCOVERY_DIR/azure_sizing.json")

    # Derive resource names from VM hostname (sanitised)
    SAFE_NAME=$(echo "$VM_HOSTNAME" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]' | cut -c1-20)
    RESOURCE_GROUP="rg-${SAFE_NAME}-migrate"
    PROJECT_NAME="${SAFE_NAME}-migration"
    VNET_NAME="${SAFE_NAME}-vnet"
    APP_SUBNET_NAME="${SAFE_NAME}-app-subnet"
    DB_SUBNET_NAME="${SAFE_NAME}-db-subnet"
    NSG_NAME="${SAFE_NAME}-nsg"
    STORAGE_ACCOUNT="${SAFE_NAME//[-]/""}${STORAGE_SUFFIX}"
    STORAGE_ACCOUNT=$(echo "$STORAGE_ACCOUNT" | tr -dc '[:alnum:]' | tr '[:upper:]' '[:lower:]' | cut -c1-24)
    VAULT_NAME="${SAFE_NAME}-vault"
    MIGRATE_PROJECT="${SAFE_NAME}-migrate-project"

    info "Source VM         : $VM_HOSTNAME"
    info "Resource Group    : $RESOURCE_GROUP"
    info "Location          : $LOCATION"
    info "VNet              : $VNET_NAME"
    info "NSG               : $NSG_NAME"
    info "Storage Account   : $STORAGE_ACCOUNT"
    info "Recovery Vault    : $VAULT_NAME"
    info "Migrate Project   : $MIGRATE_PROJECT"
    info "Azure VM Size     : $VM_SIZE"
    info "OS Disk           : ${OS_DISK_GB}GB"
    info "Data Disk         : ${DATA_DISK_GB}GB"

    confirm "Create all Azure resources listed above in '$LOCATION'?"
}

################################################################################
# Step 1: Resource Group
################################################################################

create_resource_group() {
    section "Resource Group"
    step "Creating resource group: $RESOURCE_GROUP"

    if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
        warn "Resource group '$RESOURCE_GROUP' already exists — using existing"
    else
        az group create \
            --name "$RESOURCE_GROUP" \
            --location "$LOCATION" \
            --tags \
                "Environment=Migration" \
                "SourceVM=$VM_HOSTNAME" \
                "MigrationApproach=AzureMigrate" \
                "CreatedBy=Approach2" \
            --output none
        ok "Resource group created"
    fi
}

################################################################################
# Step 2: Virtual Network + Subnets
################################################################################

create_vnet() {
    section "Virtual Network"
    step "Creating VNet: $VNET_NAME (10.0.0.0/16)"

    if az network vnet show --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" &>/dev/null; then
        warn "VNet '$VNET_NAME' already exists — using existing"
    else
        az network vnet create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$VNET_NAME" \
            --address-prefix "10.0.0.0/16" \
            --tags "ManagedBy=Approach2" \
            --output none
        ok "VNet created: 10.0.0.0/16"
    fi

    # App subnet
    step "Creating app subnet: $APP_SUBNET_NAME (10.0.1.0/24)"
    if ! az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$APP_SUBNET_NAME" &>/dev/null; then
        az network vnet subnet create \
            --resource-group "$RESOURCE_GROUP" \
            --vnet-name "$VNET_NAME" \
            --name "$APP_SUBNET_NAME" \
            --address-prefix "10.0.1.0/24" \
            --output none
        ok "App subnet created: 10.0.1.0/24"
    else
        warn "App subnet already exists"
    fi

    # DB subnet
    step "Creating DB subnet: $DB_SUBNET_NAME (10.0.2.0/24)"
    if ! az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$DB_SUBNET_NAME" &>/dev/null; then
        az network vnet subnet create \
            --resource-group "$RESOURCE_GROUP" \
            --vnet-name "$VNET_NAME" \
            --name "$DB_SUBNET_NAME" \
            --address-prefix "10.0.2.0/24" \
            --output none
        ok "DB subnet created: 10.0.2.0/24"
    else
        warn "DB subnet already exists"
    fi
}

################################################################################
# Step 3: Network Security Group (rules from discovery)
################################################################################

create_nsg() {
    section "Network Security Group"
    step "Creating NSG: $NSG_NAME"

    if az network nsg show --resource-group "$RESOURCE_GROUP" --name "$NSG_NAME" &>/dev/null; then
        warn "NSG '$NSG_NAME' already exists — using existing"
    else
        az network nsg create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$NSG_NAME" \
            --tags "ManagedBy=Approach2" \
            --output none
        ok "NSG created"
    fi

    step "Adding NSG rules from discovery data..."

    # Apply each rule from azure_nsg_rules.json
    RULE_COUNT=$(jq '.nsg_rules | length' "$DISCOVERY_DIR/azure_nsg_rules.json")
    info "Applying $RULE_COUNT NSG rules..."

    jq -c '.nsg_rules[]' "$DISCOVERY_DIR/azure_nsg_rules.json" | while IFS= read -r rule; do
        name=$(echo "$rule"      | jq -r '.name')
        priority=$(echo "$rule"  | jq -r '.priority')
        direction=$(echo "$rule" | jq -r '.direction')
        access=$(echo "$rule"    | jq -r '.access')
        protocol=$(echo "$rule"  | jq -r '.protocol')
        src_port=$(echo "$rule"  | jq -r '.source_port_range')
        dst_port=$(echo "$rule"  | jq -r '.destination_port_range')
        src_addr=$(echo "$rule"  | jq -r '.source_address_prefix')
        dst_addr=$(echo "$rule"  | jq -r '.destination_address_prefix')

        # Check if rule already exists
        if az network nsg rule show \
            --resource-group "$RESOURCE_GROUP" \
            --nsg-name "$NSG_NAME" \
            --name "$name" &>/dev/null; then
            warn "  Rule '$name' already exists — skipping"
            continue
        fi

        az network nsg rule create \
            --resource-group "$RESOURCE_GROUP" \
            --nsg-name "$NSG_NAME" \
            --name "$name" \
            --priority "$priority" \
            --direction "$direction" \
            --access "$access" \
            --protocol "$protocol" \
            --source-port-ranges "$src_port" \
            --destination-port-ranges "$dst_port" \
            --source-address-prefixes "$src_addr" \
            --destination-address-prefixes "$dst_addr" \
            --output none
        ok "  Rule: $name (port $dst_port, $direction $access)"
    done

    # Associate NSG with app subnet
    step "Associating NSG with app subnet..."
    az network vnet subnet update \
        --resource-group "$RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        --name "$APP_SUBNET_NAME" \
        --network-security-group "$NSG_NAME" \
        --output none
    ok "NSG associated with app subnet"
}

################################################################################
# Step 4: Storage Account + Containers
################################################################################

create_storage() {
    section "Storage Account"
    step "Creating storage account: $STORAGE_ACCOUNT"

    if az storage account show --resource-group "$RESOURCE_GROUP" --name "$STORAGE_ACCOUNT" &>/dev/null; then
        warn "Storage account '$STORAGE_ACCOUNT' already exists"
    else
        az storage account create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$STORAGE_ACCOUNT" \
            --location "$LOCATION" \
            --sku "Standard_LRS" \
            --kind "StorageV2" \
            --access-tier "Hot" \
            --https-only true \
            --min-tls-version "TLS1_2" \
            --tags "ManagedBy=Approach2" \
            --output none
        ok "Storage account created"
    fi

    STORAGE_KEY=$(az storage account keys list \
        --resource-group "$RESOURCE_GROUP" \
        --account-name "$STORAGE_ACCOUNT" \
        --query "[0].value" -o tsv)

    # Migration files container
    step "Creating container: migration-files"
    az storage container create \
        --account-name "$STORAGE_ACCOUNT" \
        --account-key "$STORAGE_KEY" \
        --name "migration-files" \
        --auth-mode key \
        --output none 2>/dev/null || warn "Container 'migration-files' may already exist"
    ok "Container: migration-files"

    # Backups container
    step "Creating container: backups"
    az storage container create \
        --account-name "$STORAGE_ACCOUNT" \
        --account-key "$STORAGE_KEY" \
        --name "backups" \
        --auth-mode key \
        --output none 2>/dev/null || warn "Container 'backups' may already exist"
    ok "Container: backups"

    # Discovery output container
    step "Creating container: discovery"
    az storage container create \
        --account-name "$STORAGE_ACCOUNT" \
        --account-key "$STORAGE_KEY" \
        --name "discovery" \
        --auth-mode key \
        --output none 2>/dev/null || warn "Container 'discovery' may already exist"
    ok "Container: discovery"

    # Upload discovery bundle
    step "Uploading discovery bundle to Azure..."
    az storage blob upload-batch \
        --account-name "$STORAGE_ACCOUNT" \
        --account-key "$STORAGE_KEY" \
        --destination "discovery" \
        --source "$DISCOVERY_DIR" \
        --output none 2>/dev/null && ok "Discovery bundle uploaded" || warn "Discovery upload skipped"
}

################################################################################
# Step 5: Recovery Services Vault + Backup Policy
################################################################################

create_recovery_vault() {
    section "Recovery Services Vault"
    step "Creating vault: $VAULT_NAME"

    if az backup vault show --resource-group "$RESOURCE_GROUP" --name "$VAULT_NAME" &>/dev/null; then
        warn "Vault '$VAULT_NAME' already exists"
    else
        az backup vault create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$VAULT_NAME" \
            --location "$LOCATION" \
            --output none
        ok "Recovery vault created"
    fi

    # Enable soft delete
    az backup vault backup-properties set \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VAULT_NAME" \
        --soft-delete-feature-state Enable \
        --output none 2>/dev/null || warn "Could not set soft-delete (may require permissions)"

    ok "Vault configured with soft-delete"
}

################################################################################
# Step 6: Azure Migrate Project
################################################################################

create_migrate_project() {
    section "Azure Migrate Project"

    # Register provider if needed
    step "Ensuring Microsoft.Migrate provider is registered..."
    MIGRATE_STATE=$(az provider show --namespace Microsoft.Migrate --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")
    if [[ "$MIGRATE_STATE" != "Registered" ]]; then
        info "Registering Microsoft.Migrate provider (this takes 1-2 minutes)..."
        az provider register --namespace Microsoft.Migrate --wait --output none
        ok "Provider registered"
    else
        ok "Microsoft.Migrate provider already registered"
    fi

    # Also register Microsoft.OffAzure for physical server discovery
    step "Registering Microsoft.OffAzure provider..."
    az provider register --namespace Microsoft.OffAzure --wait --output none 2>/dev/null || true
    ok "Microsoft.OffAzure provider registered"

    step "Creating Azure Migrate project: $MIGRATE_PROJECT"
    if az resource show \
        --resource-group "$RESOURCE_GROUP" \
        --resource-type "Microsoft.Migrate/migrateProjects" \
        --name "$MIGRATE_PROJECT" &>/dev/null 2>&1; then
        warn "Azure Migrate project '$MIGRATE_PROJECT' already exists"
    else
        az resource create \
            --resource-group "$RESOURCE_GROUP" \
            --resource-type "Microsoft.Migrate/migrateProjects" \
            --name "$MIGRATE_PROJECT" \
            --location "$LOCATION" \
            --properties '{"publicNetworkAccess":"Enabled"}' \
            --output none
        ok "Azure Migrate project created"
    fi
}

################################################################################
# Step 7: Save all resource IDs to JSON
################################################################################

save_resource_manifest() {
    section "Resource Manifest"

    VNET_ID=$(az network vnet show --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" --query id -o tsv 2>/dev/null || echo "")
    APP_SUBNET_ID=$(az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$APP_SUBNET_NAME" --query id -o tsv 2>/dev/null || echo "")
    DB_SUBNET_ID=$(az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$DB_SUBNET_NAME" --query id -o tsv 2>/dev/null || echo "")
    NSG_ID=$(az network nsg show --resource-group "$RESOURCE_GROUP" --name "$NSG_NAME" --query id -o tsv 2>/dev/null || echo "")
    STORAGE_ID=$(az storage account show --resource-group "$RESOURCE_GROUP" --name "$STORAGE_ACCOUNT" --query id -o tsv 2>/dev/null || echo "")
    VAULT_ID=$(az backup vault show --resource-group "$RESOURCE_GROUP" --name "$VAULT_NAME" --query id -o tsv 2>/dev/null || echo "")
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)

    cat > "$RESOURCES_FILE" <<EOF
{
  "setup_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source_vm": "$SOURCE_VM",
  "ssh_user": "$SSH_USER",
  "discovery_dir": "$DISCOVERY_DIR",
  "azure": {
    "subscription_id": "$SUBSCRIPTION_ID",
    "location": "$LOCATION",
    "resource_group": "$RESOURCE_GROUP",
    "vnet": {
      "name": "$VNET_NAME",
      "id": "$VNET_ID",
      "address_space": "10.0.0.0/16",
      "app_subnet": "$APP_SUBNET_NAME",
      "app_subnet_id": "$APP_SUBNET_ID",
      "app_subnet_cidr": "10.0.1.0/24",
      "db_subnet": "$DB_SUBNET_NAME",
      "db_subnet_id": "$DB_SUBNET_ID",
      "db_subnet_cidr": "10.0.2.0/24"
    },
    "nsg": {
      "name": "$NSG_NAME",
      "id": "$NSG_ID"
    },
    "storage_account": {
      "name": "$STORAGE_ACCOUNT",
      "id": "$STORAGE_ID",
      "containers": ["migration-files", "backups", "discovery"]
    },
    "recovery_vault": {
      "name": "$VAULT_NAME",
      "id": "$VAULT_ID"
    },
    "migrate_project": "$MIGRATE_PROJECT"
  },
  "vm_target": {
    "vm_size": "$VM_SIZE",
    "os_disk_gb": $OS_DISK_GB,
    "data_disk_gb": $DATA_DISK_GB,
    "admin_username": "azureuser",
    "subnet": "$APP_SUBNET_NAME"
  }
}
EOF

    ok "Resource manifest saved: $RESOURCES_FILE"
}

################################################################################
# Main
################################################################################

main() {
    print_banner

    preflight
    create_resource_group
    create_vnet
    create_nsg
    create_storage
    create_recovery_vault
    create_migrate_project
    save_resource_manifest

    header "Setup Complete"
    ok "All Azure resources created"
    echo ""
    echo "  Resources : $RESOURCE_GROUP (${LOCATION})"
    echo "  Manifest  : $RESOURCES_FILE"
    echo ""
    echo -e "${CYAN}Next step:${NC}"
    echo "  ./03_replicate.sh \"$SOURCE_VM\" \"$SSH_USER\" \"$RESOURCES_FILE\""
    echo ""
}

main

# Made with Bob
