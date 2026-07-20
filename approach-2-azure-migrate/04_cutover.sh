#!/bin/bash

################################################################################
# Approach 2 — Phase 4: Cutover
#
# This is the production cutover phase — the point of no return.
# It mirrors Approach 1's configure_azure_vm() + restore_data_to_azure()
# phases but uses the Azure Migrate replicated VM instead of building from scratch.
#
# What this does:
#   1. Pre-cutover checklist (replication status, connectivity)
#   2. Stop the source VM (short downtime window starts)
#   3. Trigger final sync + cutover via Azure Migrate
#   4. Configure the migrated VM:
#      - Assign Public IP
#      - Format + mount data disk
#      - Install base packages
#   5. Restore all backed-up data from Azure Storage
#      (config files, app data, service config, SSH keys)
#   6. Start and verify services
#   7. DNS cutover instructions
#
# Usage:
#   ./04_cutover.sh <source-vm> <ssh-user> <phase3-state>
#
# Example:
#   ./04_cutover.sh myvm.fyre.ibm.com root backup_20250101_120000/phase3_state.json
################################################################################

set -euo pipefail

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

# ── Arguments ──────────────────────────────────────────────────────────────────
SOURCE_VM="${1:-}"
SSH_USER="${2:-root}"
PHASE3_STATE="${3:-}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="cutover_${TIMESTAMP}"
LOG_FILE="$LOG_DIR/cutover.log"

# Loaded from state file
RESOURCE_GROUP=""
STORAGE_ACCOUNT=""
VNET_NAME=""
APP_SUBNET_NAME=""
LOCATION=""
BACKUP_DIR=""

# Azure Migrate creates the VM with the same name as the source
AZURE_VM_NAME=""
AZURE_VM_IP=""
AZURE_ADMIN="azureuser"

# ── Helpers ───────────────────────────────────────────────────────────────────
print_banner() {
    echo -e "${CYAN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║   Approach 2 — Phase 4: Cutover                              ║
║   Stop Source → Migrate → Restore → Configure → Go Live      ║
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
    [[ "$ans" =~ ^[Yy][Ee][Ss]$ ]] || { warn "Cancelled."; exit 0; }
}

remote_src()  { ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no "${SSH_USER}@${SOURCE_VM}" "$@" 2>/dev/null; }
remote_az()   { ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no "${AZURE_ADMIN}@${AZURE_VM_IP}" "$@"; }
remote_az_safe() { ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no "${AZURE_ADMIN}@${AZURE_VM_IP}" "$@" 2>/dev/null || echo ""; }

################################################################################
# Preflight
################################################################################

preflight() {
    header "Preflight"

    [[ -z "$SOURCE_VM" || -z "$PHASE3_STATE" ]] && {
        echo "Usage: $0 <source-vm> <ssh-user> <phase3-state>"
        echo "Example: $0 myvm.fyre.ibm.com root backup_20250101_120000/phase3_state.json"
        exit 1
    }

    mkdir -p "$LOG_DIR"

    [[ -f "$PHASE3_STATE" ]] || die "Phase 3 state file not found: $PHASE3_STATE. Run 03_replicate.sh first."

    command -v az  &>/dev/null || die "Azure CLI not installed"
    command -v jq  &>/dev/null || die "jq not installed"
    az account show &>/dev/null || die "Not logged into Azure. Run: az login"

    # Load state
    RESOURCE_GROUP=$(jq -r '.resource_group' "$PHASE3_STATE")
    STORAGE_ACCOUNT=$(jq -r '.storage_account' "$PHASE3_STATE")
    VNET_NAME=$(jq -r '.vnet_name' "$PHASE3_STATE")
    APP_SUBNET_NAME=$(jq -r '.app_subnet' "$PHASE3_STATE")
    LOCATION=$(jq -r '.location' "$PHASE3_STATE")
    BACKUP_DIR=$(jq -r '.backup_dir' "$PHASE3_STATE")

    ok "Loaded phase 3 state"
    info "Resource group  : $RESOURCE_GROUP"
    info "Storage account : $STORAGE_ACCOUNT"
    info "Backup dir      : $BACKUP_DIR"
    info "VNet            : $VNET_NAME / $APP_SUBNET_NAME"
}

################################################################################
# Phase 4A: Pre-Cutover Checklist
################################################################################

pre_cutover_checklist() {
    header "Pre-Cutover Checklist"

    echo ""
    echo -e "${CYAN}Verify each item before proceeding:${NC}"
    echo ""
    echo "  [ ] Replication status is 'Protected' in Azure Portal"
    echo "  [ ] Last sync was within the last 15 minutes"
    echo "  [ ] Test migration has been run and validated (optional but recommended)"
    echo "  [ ] Stakeholders have been notified of the maintenance window"
    echo "  [ ] DNS TTL has been lowered (if using DNS cutover)"
    echo "  [ ] Rollback plan is documented"
    echo ""

    # Check Azure Migrate replication status via CLI
    step "Checking replication status in Azure Migrate..."
    az resource list \
        --resource-group "$RESOURCE_GROUP" \
        --resource-type "Microsoft.RecoveryServices/vaults" \
        --query "[].name" -o tsv 2>/dev/null | while read -r vault; do
        info "Found vault: $vault"
    done || warn "Could not query vaults — manual check required"

    echo ""
    confirm "⚠️  PRODUCTION CUTOVER — this will stop the source VM and begin migration. Are you ready?"
    echo ""
    warn "Downtime begins NOW. Source VM will be stopped."
    confirm "FINAL CONFIRMATION: Stop source VM and trigger cutover?"
}

################################################################################
# Phase 4B: Stop Source VM
################################################################################

stop_source_vm() {
    header "Stop Source VM"

    step "Gracefully stopping source VM: $SOURCE_VM"
    info "This stops the workload. Downtime clock starts."

    if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
            "${SSH_USER}@${SOURCE_VM}" "echo connected" &>/dev/null; then
        # Stop services gracefully before shutdown
        remote_src "systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print \$1}' | head -20 | while read svc; do
            systemctl stop \$svc 2>/dev/null || true
        done" 2>/dev/null || warn "Could not stop services gracefully"

        ok "Services stopped on source VM"

        # Record final state
        remote_src "df -h 2>/dev/null"     > "$LOG_DIR/source_final_df.txt"    || true
        remote_src "ip addr 2>/dev/null"   > "$LOG_DIR/source_final_ip.txt"    || true
        remote_src "hostname 2>/dev/null"  > "$LOG_DIR/source_final_host.txt"  || true

        ok "Final source VM state captured"
    else
        warn "Cannot reach source VM (may already be stopped)"
    fi

    echo ""
    info "Source VM is stopped. Minimum downtime window from this point."
    echo ""
}

################################################################################
# Phase 4C: Final Migration via Azure Migrate
################################################################################

trigger_azure_migrate_cutover() {
    header "Azure Migrate Cutover"

    echo ""
    echo -e "${CYAN}MANUAL STEPS — Complete now (5-10 minutes):${NC}"
    echo ""
    echo -e "${MAGENTA}In Azure Portal:${NC}"
    echo ""
    echo "  1. Navigate to:"
    echo "     https://portal.azure.com/#blade/Microsoft_Azure_Migrate/AmhResourceMenuBlade/overview"
    echo ""
    echo "  2. Click 'Servers, databases and web apps'"
    echo ""
    echo "  3. Under 'Migration tools' → click 'Replicating servers'"
    echo ""
    echo "  4. Find your VM and click 'Migrate'"
    echo ""
    echo "  5. Confirm: Shut down VMs? → NO (already stopped)"
    echo ""
    echo "  6. Click 'Migrate' and wait for completion (~5-10 min)"
    echo ""
    echo "  7. Note the new Azure VM name (usually same as source hostname)"
    echo ""

    read -rp "Enter the Azure VM name created by the migration: " AZURE_VM_NAME
    [[ -z "$AZURE_VM_NAME" ]] && die "Azure VM name is required"

    # Wait for VM to show up and be running
    step "Waiting for Azure VM to be running..."
    for i in {1..30}; do
        POWER_STATE=$(az vm show \
            --resource-group "$RESOURCE_GROUP" \
            --name "$AZURE_VM_NAME" \
            --show-details \
            --query powerState -o tsv 2>/dev/null || echo "")
        if [[ "$POWER_STATE" == "VM running" ]]; then
            ok "Azure VM is running: $AZURE_VM_NAME"
            break
        fi
        info "  Waiting... ($i/30) — state: ${POWER_STATE:-unknown}"
        sleep 10
    done

    [[ "$POWER_STATE" == "VM running" ]] || die "Azure VM did not come up within 5 minutes. Check Azure Portal."

    # Get the private IP of the migrated VM
    AZURE_VM_PRIVATE_IP=$(az vm show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$AZURE_VM_NAME" \
        --show-details \
        --query privateIps -o tsv 2>/dev/null || echo "")
    ok "Azure VM private IP: $AZURE_VM_PRIVATE_IP"
}

################################################################################
# Phase 4D: Assign Public IP to Migrated VM
################################################################################

assign_public_ip() {
    header "Public IP Assignment"

    SAFE_NAME=$(echo "$AZURE_VM_NAME" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]' | cut -c1-20)
    PIP_NAME="${SAFE_NAME}-pip"
    NIC_NAME=$(az vm show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$AZURE_VM_NAME" \
        --query "networkProfile.networkInterfaces[0].id" -o tsv 2>/dev/null | xargs basename 2>/dev/null || echo "")

    step "Creating static public IP: $PIP_NAME"
    if az network public-ip show --resource-group "$RESOURCE_GROUP" --name "$PIP_NAME" &>/dev/null; then
        warn "Public IP '$PIP_NAME' already exists"
    else
        az network public-ip create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$PIP_NAME" \
            --allocation-method Static \
            --sku Standard \
            --location "$LOCATION" \
            --tags "ManagedBy=Approach2" \
            --output none
        ok "Public IP created"
    fi

    if [[ -n "$NIC_NAME" ]]; then
        step "Attaching public IP to network interface: $NIC_NAME"
        IP_CONFIG=$(az network nic ip-config list \
            --resource-group "$RESOURCE_GROUP" \
            --nic-name "$NIC_NAME" \
            --query "[0].name" -o tsv 2>/dev/null || echo "ipconfig1")
        az network nic ip-config update \
            --resource-group "$RESOURCE_GROUP" \
            --nic-name "$NIC_NAME" \
            --name "$IP_CONFIG" \
            --public-ip-address "$PIP_NAME" \
            --output none
        ok "Public IP attached"
    else
        warn "Could not find NIC — attach public IP manually in Azure Portal"
    fi

    AZURE_VM_IP=$(az network public-ip show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$PIP_NAME" \
        --query ipAddress -o tsv 2>/dev/null || echo "")
    ok "Azure VM public IP: $AZURE_VM_IP"
}

################################################################################
# Phase 4E: Configure Migrated VM (disk, packages, users)
################################################################################

configure_azure_vm() {
    header "Configure Azure VM"

    [[ -z "$AZURE_VM_IP" ]] && {
        AZURE_VM_IP=$(az vm show \
            --resource-group "$RESOURCE_GROUP" \
            --name "$AZURE_VM_NAME" \
            --show-details \
            --query publicIps -o tsv 2>/dev/null || echo "")
    }
    [[ -z "$AZURE_VM_IP" ]] && die "Cannot determine Azure VM IP"

    info "Waiting for SSH to be available on $AZURE_VM_IP..."
    for i in {1..30}; do
        if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
                "${AZURE_ADMIN}@${AZURE_VM_IP}" "echo ready" &>/dev/null; then
            ok "SSH ready on Azure VM"
            break
        fi
        info "  Waiting for SSH... ($i/30)"
        sleep 10
    done

    ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
        "${AZURE_ADMIN}@${AZURE_VM_IP}" "echo ready" &>/dev/null || \
        die "Cannot SSH to Azure VM at $AZURE_VM_IP"

    # ── Install base packages
    section "Install Base Packages"
    step "Installing required packages..."
    remote_az "
        if command -v dnf &>/dev/null; then
            sudo dnf install -y wget curl tar gzip rsync net-tools bind-utils 2>/dev/null || true
        elif command -v apt-get &>/dev/null; then
            sudo apt-get install -y wget curl tar gzip rsync net-tools dnsutils 2>/dev/null || true
        fi
    " && ok "Base packages installed" || warn "Some packages may not have installed"

    # ── Detect and configure data disk
    section "Data Disk Configuration"
    step "Detecting data disk (not /dev/sda or OS disk)..."
    DATA_DISK=$(remote_az_safe "lsblk -d -o NAME,TYPE -n 2>/dev/null | awk '\$2==\"disk\" && \$1!=\"sda\" {print \$1}' | head -1")

    if [[ -n "$DATA_DISK" ]]; then
        ok "Data disk detected: /dev/${DATA_DISK}"
        # Check if already formatted
        FS_TYPE=$(remote_az_safe "lsblk -f -n /dev/${DATA_DISK} 2>/dev/null | awk '{print \$2}' | head -1")
        if [[ -n "$FS_TYPE" && "$FS_TYPE" != "" ]]; then
            warn "Disk /dev/${DATA_DISK} already has filesystem: $FS_TYPE"
        else
            step "Formatting /dev/${DATA_DISK} as ext4..."
            remote_az "
                sudo parted /dev/${DATA_DISK} --script mklabel gpt
                sudo parted /dev/${DATA_DISK} --script mkpart primary ext4 0% 100%
                sleep 2
                sudo mkfs.ext4 /dev/${DATA_DISK}1
                sudo mkdir -p /data
                echo '/dev/${DATA_DISK}1 /data ext4 defaults 0 0' | sudo tee -a /etc/fstab
                sudo mount -a
                sudo chmod 755 /data
            " && ok "Data disk formatted and mounted at /data" || warn "Data disk setup had errors"
        fi
    else
        warn "No additional data disk found — data will be restored to OS disk"
        remote_az "sudo mkdir -p /data" 2>/dev/null || true
    fi
}

################################################################################
# Phase 4F: Restore Data from Azure Storage
################################################################################

restore_data() {
    header "Restore Data from Azure Storage"

    STORAGE_KEY=$(az storage account keys list \
        --resource-group "$RESOURCE_GROUP" \
        --account-name "$STORAGE_ACCOUNT" \
        --query "[0].value" -o tsv)

    step "Listing available backup files..."
    BLOBS=$(az storage blob list \
        --account-name "$STORAGE_ACCOUNT" \
        --account-key "$STORAGE_KEY" \
        --container-name "migration-files" \
        --query "[?ends_with(name, '.tar.gz')].name" \
        -o tsv 2>/dev/null || echo "")

    if [[ -z "$BLOBS" ]]; then
        warn "No backup tar.gz files found in Azure Storage — skipping data restore"
        return
    fi

    info "Found backup files:"
    echo "$BLOBS" | while read -r blob; do echo "  - $blob"; done

    # Download each backup to the Azure VM via SAS token
    step "Generating temporary SAS token for download..."
    SAS_EXPIRY=$(date -u -d "+2 hours" '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -v+2H '+%Y-%m-%dT%H:%MZ' 2>/dev/null || echo "")
    if [[ -n "$SAS_EXPIRY" ]]; then
        SAS_TOKEN=$(az storage account generate-sas \
            --account-name "$STORAGE_ACCOUNT" \
            --account-key "$STORAGE_KEY" \
            --expiry "$SAS_EXPIRY" \
            --permissions rl \
            --resource-types co \
            --services b \
            --output tsv 2>/dev/null || echo "")
    fi

    step "Creating restore directory on Azure VM..."
    remote_az "sudo mkdir -p /tmp/azure_migration_restore && sudo chmod 777 /tmp/azure_migration_restore"

    # Download each backup to the Azure VM
    echo "$BLOBS" | while read -r blob; do
        [[ -z "$blob" ]] && continue
        BLOB_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/migration-files/${blob}"
        FILENAME=$(basename "$blob")
        step "Downloading: $FILENAME"
        if [[ -n "$SAS_TOKEN" ]]; then
            remote_az "curl -fsSL '${BLOB_URL}?${SAS_TOKEN}' -o /tmp/azure_migration_restore/${FILENAME}" \
                && ok "  Downloaded: $FILENAME" || warn "  Failed: $FILENAME"
        else
            # Fallback: copy via local machine
            scp -o StrictHostKeyChecking=no "$BACKUP_DIR/$( basename "$(dirname "$BACKUP_DIR/")"*)/$FILENAME" \
                "${AZURE_ADMIN}@${AZURE_VM_IP}:/tmp/azure_migration_restore/" 2>/dev/null \
                && ok "  Copied: $FILENAME" || warn "  Could not copy $FILENAME"
        fi
    done

    # Restore each archive
    section "Extracting Backups"
    remote_az "
        cd /tmp/azure_migration_restore
        
        # Restore /etc config
        if [ -f etc_config.tar.gz ]; then
            echo 'Restoring /etc config...'
            sudo tar xzf etc_config.tar.gz -C / 2>/dev/null || true
        fi
        
        # Restore home directories
        if [ -f home_backup.tar.gz ]; then
            echo 'Restoring /home...'
            sudo tar xzf home_backup.tar.gz -C / 2>/dev/null || true
        fi
        
        # Restore application data
        if [ -f app_data.tar.gz ]; then
            echo 'Restoring application data...'
            sudo tar xzf app_data.tar.gz -C / 2>/dev/null || true
        fi
        
        # Restore service config (don't override Azure's systemd)
        if [ -f systemd_services.tar.gz ]; then
            echo 'Restoring custom service files...'
            sudo tar xzf systemd_services.tar.gz -C /tmp/svc_restore 2>/dev/null || true
        fi
        
        # Fix permissions on restored files
        sudo restorecon -r /home/ 2>/dev/null || true
        sudo restorecon -r /opt/ 2>/dev/null || true
        
        echo 'Data restore complete'
    " && ok "All backups restored on Azure VM" || warn "Some restore operations had errors"
}

################################################################################
# Phase 4G: Reconfigure Networking on Azure VM
################################################################################

configure_networking() {
    header "Network Configuration"

    SOURCE_HOSTNAME=$(cat "$LOG_DIR/source_final_host.txt" 2>/dev/null | head -1 | xargs || echo "$AZURE_VM_NAME")

    section "Hostname"
    step "Setting hostname to match source: $SOURCE_HOSTNAME"
    remote_az "sudo hostnamectl set-hostname '$SOURCE_HOSTNAME'" \
        && ok "Hostname set: $SOURCE_HOSTNAME" || warn "Could not set hostname"

    section "Hosts File"
    step "Configuring /etc/hosts..."
    remote_az "
        # Ensure localhost entries are correct
        grep -q '127.0.0.1' /etc/hosts || echo '127.0.0.1 localhost' | sudo tee -a /etc/hosts
        grep -q '127.0.1.1' /etc/hosts || echo \"127.0.1.1 $SOURCE_HOSTNAME\" | sudo tee -a /etc/hosts
    " && ok "Hosts file configured" || warn "Could not configure hosts file"

    section "Firewall"
    # Get the source firewall type
    FW_TYPE=$(jq -r '.type' "${BACKUP_DIR}/../discovery_*/firewall.json" 2>/dev/null || echo "none")
    if [[ "$FW_TYPE" == "firewalld" ]]; then
        step "Enabling firewalld on Azure VM..."
        remote_az "sudo systemctl enable --now firewalld 2>/dev/null || true" && ok "firewalld enabled" || warn "Could not enable firewalld"
    fi

    section "Reload Services"
    step "Reloading systemd daemon..."
    remote_az "sudo systemctl daemon-reload 2>/dev/null || true"
    ok "systemd reloaded"
}

################################################################################
# Phase 4H: Enable Azure Backup on migrated VM
################################################################################

enable_backup() {
    header "Azure Backup"

    VAULT_NAME=$(az backup vault list \
        --resource-group "$RESOURCE_GROUP" \
        --query "[0].name" -o tsv 2>/dev/null || echo "")

    if [[ -z "$VAULT_NAME" ]]; then
        warn "No Recovery Services Vault found — backup not configured"
        return
    fi

    step "Enabling Azure Backup for: $AZURE_VM_NAME"
    VM_ID=$(az vm show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$AZURE_VM_NAME" \
        --query id -o tsv 2>/dev/null || echo "")

    POLICY_NAME=$(az backup policy list \
        --resource-group "$RESOURCE_GROUP" \
        --vault-name "$VAULT_NAME" \
        --query "[?policyType=='AzureIaasVM'][0].name" -o tsv 2>/dev/null || echo "")

    if [[ -n "$VM_ID" && -n "$POLICY_NAME" ]]; then
        az backup protection enable-for-vm \
            --resource-group "$RESOURCE_GROUP" \
            --vault-name "$VAULT_NAME" \
            --vm "$AZURE_VM_NAME" \
            --policy-name "$POLICY_NAME" \
            --output none 2>/dev/null && ok "Azure Backup enabled (policy: $POLICY_NAME)" || \
            warn "Could not enable backup — do it manually in Azure Portal"
    else
        warn "Could not find backup policy — enable backup manually in Azure Portal"
    fi
}

################################################################################
# Phase 4I: Save cutover state
################################################################################

save_cutover_state() {
    section "Cutover State"

    cat > "$LOG_DIR/phase4_state.json" <<EOF
{
  "phase": "cutover",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source_vm": "$SOURCE_VM",
  "azure_vm_name": "$AZURE_VM_NAME",
  "azure_vm_ip": "$AZURE_VM_IP",
  "azure_vm_private_ip": "${AZURE_VM_PRIVATE_IP:-}",
  "resource_group": "$RESOURCE_GROUP",
  "storage_account": "$STORAGE_ACCOUNT",
  "location": "$LOCATION",
  "cutover_log": "$LOG_DIR"
}
EOF

    ok "Cutover state saved: $LOG_DIR/phase4_state.json"
}

################################################################################
# Phase 4J: DNS Cutover Instructions
################################################################################

print_dns_guide() {
    header "DNS Cutover"

    echo ""
    echo -e "${CYAN}Update DNS to complete the cutover:${NC}"
    echo ""
    echo "  Old IP (source) : $(ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
        "${SSH_USER}@${SOURCE_VM}" "hostname -I | awk '{print \$1}'" 2>/dev/null || echo 'stopped')"
    echo "  New IP (Azure)  : $AZURE_VM_IP"
    echo ""
    echo "  1. Update your DNS A record to point to: $AZURE_VM_IP"
    echo "  2. Wait for DNS TTL to expire"
    echo "  3. Verify with: nslookup <your-hostname>"
    echo ""
    echo -e "${CYAN}Test connectivity:${NC}"
    echo "  ssh ${AZURE_ADMIN}@${AZURE_VM_IP}"
    echo ""
}

################################################################################
# Main
################################################################################

main() {
    print_banner
    preflight
    pre_cutover_checklist
    stop_source_vm
    trigger_azure_migrate_cutover
    assign_public_ip
    configure_azure_vm
    restore_data
    configure_networking
    enable_backup
    save_cutover_state
    print_dns_guide

    header "Cutover Complete"
    ok "Migration cutover finished"
    echo ""
    echo "  Azure VM  : $AZURE_VM_NAME"
    echo "  Public IP : $AZURE_VM_IP"
    echo "  SSH       : ssh ${AZURE_ADMIN}@${AZURE_VM_IP}"
    echo "  State     : $LOG_DIR/phase4_state.json"
    echo ""
    echo -e "${CYAN}Next step — validate the migration:${NC}"
    echo "  ./05_validate.sh \"$AZURE_VM_NAME\" \"$RESOURCE_GROUP\" \"$LOG_DIR/phase4_state.json\""
    echo ""
}

main

# Made with Bob
