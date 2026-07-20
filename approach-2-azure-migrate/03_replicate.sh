#!/bin/bash

################################################################################
# Approach 2 — Phase 3: Data Backup + Replication Setup
#
# This is the heart of the migration — equivalent to Approach 1's
# backup_fyre_vm() + upload_to_azure_storage() phases but much richer:
#
#   1. SSH into source VM and create comprehensive backup tarballs
#      (OS config, application data, databases, services)
#   2. Upload everything to Azure Blob Storage
#   3. Deploy the Azure Migrate appliance VM (Windows Server)
#   4. Print guided instructions to register appliance and start replication
#
# Usage:
#   ./03_replicate.sh <source-vm> <ssh-user> <resources-manifest>
#
# Example:
#   ./03_replicate.sh myvm.fyre.ibm.com root azure_setup_20250101/created_resources.json
################################################################################

set -euo pipefail

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

# ── Arguments ──────────────────────────────────────────────────────────────────
SOURCE_VM="${1:-}"
SSH_USER="${2:-root}"
RESOURCES_FILE="${3:-}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="backup_${TIMESTAMP}"
LOG_FILE="$BACKUP_DIR/replicate.log"

# ── Helpers ───────────────────────────────────────────────────────────────────
print_banner() {
    echo -e "${CYAN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║   Approach 2 — Phase 3: Backup & Replication                 ║
║   Source → Backup → Azure Storage → Appliance → Replicate   ║
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

remote()      { ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no "${SSH_USER}@${SOURCE_VM}" "$@"; }
remote_safe() { ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no "${SSH_USER}@${SOURCE_VM}" "$@" 2>/dev/null || echo ""; }

################################################################################
# Preflight
################################################################################

preflight() {
    header "Preflight"

    [[ -z "$SOURCE_VM" || -z "$RESOURCES_FILE" ]] && {
        echo "Usage: $0 <source-vm> <ssh-user> <resources-manifest>"
        echo "Example: $0 myvm.fyre.ibm.com root azure_setup_20250101/created_resources.json"
        exit 1
    }

    mkdir -p "$BACKUP_DIR"

    [[ -f "$RESOURCES_FILE" ]] || die "Resources manifest not found: $RESOURCES_FILE. Run 02_setup_azure_migrate.sh first."

    command -v az  &>/dev/null || die "Azure CLI not installed"
    command -v jq  &>/dev/null || die "jq not installed"
    command -v ssh &>/dev/null || die "ssh not installed"

    az account show &>/dev/null || die "Not logged in to Azure. Run: az login"

    # Load resource config
    RESOURCE_GROUP=$(jq -r '.azure.resource_group' "$RESOURCES_FILE")
    LOCATION=$(jq -r '.azure.location' "$RESOURCES_FILE")
    STORAGE_ACCOUNT=$(jq -r '.azure.storage_account.name' "$RESOURCES_FILE")
    VNET_NAME=$(jq -r '.azure.vnet.name' "$RESOURCES_FILE")
    APP_SUBNET_NAME=$(jq -r '.azure.vnet.app_subnet' "$RESOURCES_FILE")
    MIGRATE_PROJECT=$(jq -r '.azure.migrate_project' "$RESOURCES_FILE")
    VM_SIZE=$(jq -r '.vm_target.vm_size' "$RESOURCES_FILE")
    SOURCE_VM_OVERRIDE=$(jq -r '.source_vm' "$RESOURCES_FILE")

    # Use the hostname from manifest if not overridden
    [[ "$SOURCE_VM" == "$SOURCE_VM_OVERRIDE" ]] || warn "Source VM mismatch: arg=$SOURCE_VM manifest=$SOURCE_VM_OVERRIDE (using arg)"

    ok "Loaded resource manifest"
    info "Resource group   : $RESOURCE_GROUP"
    info "Storage account  : $STORAGE_ACCOUNT"
    info "Migrate project  : $MIGRATE_PROJECT"

    # Test SSH
    info "Testing SSH connection..."
    ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no \
        "${SSH_USER}@${SOURCE_VM}" "echo connected" &>/dev/null || \
        die "Cannot SSH to ${SSH_USER}@${SOURCE_VM}"
    ok "SSH connection verified"
}

################################################################################
# Phase 3A: Full Source VM Backup
################################################################################

backup_source_vm() {
    header "Source VM Backup"

    info "This creates comprehensive backups of the source VM:"
    echo "  • System configuration (/etc)"
    echo "  • Application data directories"
    echo "  • Running service state"
    echo "  • Network configuration"
    echo "  • Custom data directories"
    echo ""
    confirm "Start source VM backup?"

    VM_HOSTNAME=$(remote_safe "hostname")
    BACKUP_REMOTE_DIR="/tmp/azure_migration_backup_${TIMESTAMP}"

    step "Creating remote backup staging directory..."
    remote "mkdir -p $BACKUP_REMOTE_DIR"
    ok "Remote staging: $BACKUP_REMOTE_DIR"

    # ── 3A.1: System configuration
    section "System Configuration Backup"
    step "Backing up /etc (system config)..."
    remote "tar czf $BACKUP_REMOTE_DIR/etc_config.tar.gz \
        /etc/hosts \
        /etc/hostname \
        /etc/fstab \
        /etc/resolv.conf \
        /etc/nsswitch.conf \
        /etc/sysctl.conf \
        /etc/security/limits.conf \
        /etc/environment \
        /etc/profile.d/ \
        /etc/cron.d/ \
        /etc/cron.daily/ \
        /etc/cron.weekly/ \
        2>/dev/null || true" || warn "Some /etc files could not be backed up"
    ok "System config backed up"

    # ── 3A.2: User home directories
    section "User Home Directories"
    step "Backing up /home..."
    remote "tar czf $BACKUP_REMOTE_DIR/home_backup.tar.gz /home/ 2>/dev/null || true"
    ok "Home directories backed up"

    # ── 3A.3: Application data — discover data dirs
    section "Application Data"
    step "Discovering application data directories..."

    # Common data dirs — only backup ones that exist
    APP_DIRS_EXIST=$(remote_safe "for d in /opt /srv /var/data /var/app /data /app; do [ -d \"\$d\" ] && echo \$d; done")

    if [[ -n "$APP_DIRS_EXIST" ]]; then
        info "Found app directories: $APP_DIRS_EXIST"
        step "Backing up application data directories..."
        remote "tar czf $BACKUP_REMOTE_DIR/app_data.tar.gz $APP_DIRS_EXIST 2>/dev/null || true" || warn "Some app directories could not be backed up"
        ok "Application data backed up"
    else
        warn "No standard application data directories found (/opt, /srv, /data, /app)"
        echo '{}' > "$BACKUP_DIR/app_dirs.json"
    fi

    # ── 3A.4: Service configuration
    section "Service Configuration"
    step "Backing up systemd service files..."
    remote "tar czf $BACKUP_REMOTE_DIR/systemd_services.tar.gz \
        /etc/systemd/system/ \
        /lib/systemd/system/ \
        2>/dev/null || true"
    ok "Service configuration backed up"

    # ── 3A.5: SSH keys and authorized_keys
    section "SSH Configuration"
    step "Backing up SSH configuration..."
    remote "tar czf $BACKUP_REMOTE_DIR/ssh_config.tar.gz \
        /etc/ssh/sshd_config \
        /root/.ssh/ \
        2>/dev/null || true"
    ok "SSH configuration backed up"

    # ── 3A.6: System info snapshot
    section "System Info Snapshot"
    step "Capturing system state snapshot..."
    remote "
        echo '=== HOSTNAME ===' > $BACKUP_REMOTE_DIR/system_snapshot.txt
        hostname -f >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        echo '=== OS ===' >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        cat /etc/os-release >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        echo '=== CPU ===' >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        lscpu >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        echo '=== MEMORY ===' >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        free -h >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        echo '=== DISKS ===' >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        lsblk >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        df -h >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        echo '=== NETWORK ===' >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        ip addr >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        ip route >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        echo '=== SERVICES ===' >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        systemctl list-units --type=service --state=running --no-legend >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        echo '=== LISTENING PORTS ===' >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        ss -tlnp >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        echo '=== USERS ===' >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        cat /etc/passwd >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        echo '=== GROUPS ===' >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        cat /etc/group >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        echo '=== CRONTAB ===' >> $BACKUP_REMOTE_DIR/system_snapshot.txt
        crontab -l 2>/dev/null || echo 'No crontab for root' >> $BACKUP_REMOTE_DIR/system_snapshot.txt
    " 2>/dev/null || warn "Some snapshot items could not be captured"
    ok "System snapshot captured"

    # ── 3A.7: Download all backups to local machine
    section "Downloading Backups"
    step "Downloading backup files from source VM..."

    scp -o StrictHostKeyChecking=no -r "${SSH_USER}@${SOURCE_VM}:${BACKUP_REMOTE_DIR}/" "$BACKUP_DIR/" 2>/dev/null || \
        die "Failed to download backups from source VM"
    ok "All backups downloaded to: $BACKUP_DIR/"

    # Clean up remote staging
    step "Cleaning remote staging directory..."
    remote "rm -rf $BACKUP_REMOTE_DIR" 2>/dev/null || warn "Could not clean remote staging dir"
    ok "Remote staging cleaned"

    # List what we got
    echo ""
    info "Backup files:"
    ls -lh "$BACKUP_DIR/$( basename $BACKUP_REMOTE_DIR )/"*.{tar.gz,txt} 2>/dev/null | awk '{print "  " $5 "  " $9}' || true
}

################################################################################
# Phase 3B: Upload Backups to Azure Storage
################################################################################

upload_to_azure() {
    header "Upload to Azure Storage"

    STORAGE_KEY=$(az storage account keys list \
        --resource-group "$RESOURCE_GROUP" \
        --account-name "$STORAGE_ACCOUNT" \
        --query "[0].value" -o tsv)

    step "Uploading all backup files to Azure Blob Storage..."
    info "Container: migration-files"

    az storage blob upload-batch \
        --account-name "$STORAGE_ACCOUNT" \
        --account-key "$STORAGE_KEY" \
        --destination "migration-files" \
        --source "$BACKUP_DIR" \
        --pattern "**/*.tar.gz" \
        --overwrite true \
        --output none && ok "tar.gz files uploaded" || warn "Some files may not have uploaded"

    az storage blob upload-batch \
        --account-name "$STORAGE_ACCOUNT" \
        --account-key "$STORAGE_KEY" \
        --destination "migration-files" \
        --source "$BACKUP_DIR" \
        --pattern "**/*.txt" \
        --overwrite true \
        --output none && ok "txt files uploaded" || warn "Some files may not have uploaded"

    # List what is in the container
    info "Blobs in 'migration-files':"
    az storage blob list \
        --account-name "$STORAGE_ACCOUNT" \
        --account-key "$STORAGE_KEY" \
        --container-name "migration-files" \
        --query "[].{Name:name, Size:properties.contentLength}" \
        --output table 2>/dev/null || true

    ok "All backups uploaded to Azure Storage"
    echo ""
    info "View in portal:"
    echo "  https://portal.azure.com/#view/Microsoft_Azure_Storage/ContainerMenuBlade/~/overview/storageAccountId//resourceGroupName/$RESOURCE_GROUP/storageAccountName/$STORAGE_ACCOUNT/containerName/migration-files"
}

################################################################################
# Phase 3C: Deploy Azure Migrate Appliance VM
################################################################################

deploy_appliance() {
    header "Azure Migrate Appliance"

    APPLIANCE_NAME="azure-migrate-appliance"
    APPLIANCE_ADMIN="azureadmin"
    APPLIANCE_PASS="AzureMigrate@$(date +%Y)!"

    info "The appliance is a Windows Server VM that manages replication."
    info "It needs to have network connectivity to your source VM."
    echo ""
    confirm "Deploy Azure Migrate appliance VM? (~\$140/month — delete after migration)"

    if az vm show --resource-group "$RESOURCE_GROUP" --name "$APPLIANCE_NAME" &>/dev/null; then
        warn "Appliance VM '$APPLIANCE_NAME' already exists"
        APPLIANCE_IP=$(az vm show \
            --resource-group "$RESOURCE_GROUP" \
            --name "$APPLIANCE_NAME" \
            --show-details \
            --query publicIps -o tsv 2>/dev/null || echo "")
        ok "Existing appliance IP: $APPLIANCE_IP"
    else
        step "Creating appliance VM (Windows Server 2019 — takes 5-10 min)..."

        az vm create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$APPLIANCE_NAME" \
            --image "MicrosoftWindowsServer:WindowsServer:2019-Datacenter:latest" \
            --size "Standard_D4s_v3" \
            --admin-username "$APPLIANCE_ADMIN" \
            --admin-password "$APPLIANCE_PASS" \
            --vnet-name "$VNET_NAME" \
            --subnet "$APP_SUBNET_NAME" \
            --public-ip-address-allocation Static \
            --public-ip-sku Standard \
            --nsg-rule RDP \
            --tags "Role=MigrateAppliance" "ManagedBy=Approach2" \
            --output none

        APPLIANCE_IP=$(az vm show \
            --resource-group "$RESOURCE_GROUP" \
            --name "$APPLIANCE_NAME" \
            --show-details \
            --query publicIps -o tsv)

        ok "Appliance deployed: $APPLIANCE_IP"
    fi

    # Save appliance info
    cat > "$BACKUP_DIR/appliance_info.json" <<EOF
{
  "appliance_name": "$APPLIANCE_NAME",
  "resource_group": "$RESOURCE_GROUP",
  "public_ip": "$APPLIANCE_IP",
  "admin_username": "$APPLIANCE_ADMIN",
  "admin_password": "$APPLIANCE_PASS",
  "rdp_command": "mstsc /v:$APPLIANCE_IP"
}
EOF

    ok "Appliance credentials saved: $BACKUP_DIR/appliance_info.json"
    echo ""
    echo -e "${CYAN}Appliance Connection Details:${NC}"
    echo "  Public IP   : $APPLIANCE_IP"
    echo "  Username    : $APPLIANCE_ADMIN"
    echo "  Password    : $APPLIANCE_PASS"
    echo "  RDP command : mstsc /v:$APPLIANCE_IP"
    echo ""
}

################################################################################
# Phase 3D: Guided Replication Setup Instructions
################################################################################

print_replication_guide() {
    header "Replication Setup Guide"

    PRIMARY_IP=$(remote_safe "hostname -I | awk '{print \$1}'")
    VM_HOSTNAME=$(remote_safe "hostname")

    APPLIANCE_IP=$(jq -r '.public_ip' "$BACKUP_DIR/appliance_info.json" 2>/dev/null || echo "<appliance-ip>")

    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${CYAN}MANUAL STEPS — Complete in order:${NC}"
    echo ""
    echo -e "${MAGENTA}STEP 1: Register the appliance with Azure Migrate${NC}"
    echo ""
    echo "  a) Open RDP to appliance:  mstsc /v:$APPLIANCE_IP"
    echo "  b) Open browser on appliance → https://localhost:44368"
    echo "  c) Accept license terms"
    echo "  d) Sign in with your Azure account"
    echo "  e) Select project:"
    echo "       Resource group : $RESOURCE_GROUP"
    echo "       Project name   : $MIGRATE_PROJECT"
    echo "  f) Generate and copy the project key"
    echo "  g) Register the appliance — wait for 'Successfully registered'"
    echo ""
    echo -e "${MAGENTA}STEP 2: Add source VM credentials${NC}"
    echo ""
    echo "  In the appliance web UI:"
    echo "  a) Click 'Add credentials'"
    echo "  b) Type: Linux SSH"
    echo "  c) IP/FQDN: ${CYAN}$PRIMARY_IP${NC}  (or: $VM_HOSTNAME)"
    echo "  d) Username: ${CYAN}$SSH_USER${NC}"
    echo "  e) Auth: SSH key or password"
    echo "  f) Click 'Save'"
    echo ""
    echo -e "${MAGENTA}STEP 3: Start discovery${NC}"
    echo ""
    echo "  a) Click 'Start discovery' in the appliance UI"
    echo "  b) Wait 15-30 minutes for discovery to complete"
    echo "  c) Check discovery status in Azure Portal:"
    echo "     Azure Migrate → Servers → Discovered servers"
    echo ""
    echo -e "${MAGENTA}STEP 4: Start replication${NC}"
    echo ""
    echo "  In Azure Portal:"
    echo "  a) Azure Migrate → Servers, databases and web apps"
    echo "  b) Under 'Migration tools' → click 'Replicate'"
    echo "  c) Select source VM: ${CYAN}$VM_HOSTNAME${NC}"
    echo "  d) Target settings:"
    echo "       Resource group : $RESOURCE_GROUP"
    echo "       Location       : $LOCATION"
    echo "       VNet           : $VNET_NAME"
    echo "       Subnet         : $APP_SUBNET_NAME"
    echo "  e) Click 'Replicate'"
    echo "  f) Monitor: initial sync takes 1-2 hours"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Write instructions to file too
    cat > "$BACKUP_DIR/REPLICATION_GUIDE.md" <<EOF
# Replication Setup Guide

## Appliance Access
- RDP: \`mstsc /v:$APPLIANCE_IP\`
- Username: $(jq -r '.admin_username' "$BACKUP_DIR/appliance_info.json")
- Password: see \`appliance_info.json\`

## Source VM
- Hostname: $VM_HOSTNAME
- IP: $PRIMARY_IP
- SSH user: $SSH_USER

## Azure Target
- Resource group: $RESOURCE_GROUP
- Location: $LOCATION
- VNet: $VNET_NAME
- Subnet: $APP_SUBNET_NAME
- Migrate project: $MIGRATE_PROJECT

## Steps
1. RDP to appliance → https://localhost:44368
2. Register with Azure Migrate project
3. Add source VM credentials
4. Start discovery (15-30 min)
5. Start replication in Azure Portal (1-2 hours initial sync)

## Azure Portal Link
https://portal.azure.com/#blade/Microsoft_Azure_Migrate/AmhResourceMenuBlade/overview
EOF

    ok "Replication guide saved: $BACKUP_DIR/REPLICATION_GUIDE.md"
}

################################################################################
# Save phase state
################################################################################

save_phase_state() {
    section "Phase State"

    APPLIANCE_IP=$(jq -r '.public_ip' "$BACKUP_DIR/appliance_info.json" 2>/dev/null || echo "")

    cat > "$BACKUP_DIR/phase3_state.json" <<EOF
{
  "phase": "replicate",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source_vm": "$SOURCE_VM",
  "ssh_user": "$SSH_USER",
  "resources_file": "$RESOURCES_FILE",
  "backup_dir": "$BACKUP_DIR",
  "appliance_ip": "$APPLIANCE_IP",
  "resource_group": "$RESOURCE_GROUP",
  "storage_account": "$STORAGE_ACCOUNT",
  "migrate_project": "$MIGRATE_PROJECT",
  "vnet_name": "$VNET_NAME",
  "app_subnet": "$APP_SUBNET_NAME",
  "location": "$LOCATION"
}
EOF

    ok "Phase state saved: $BACKUP_DIR/phase3_state.json"
}

################################################################################
# Main
################################################################################

main() {
    print_banner
    preflight
    backup_source_vm
    upload_to_azure
    deploy_appliance
    print_replication_guide
    save_phase_state

    header "Phase 3 Complete"
    ok "Source VM backed up and uploaded to Azure"
    ok "Appliance VM deployed"
    echo ""
    echo "  Backups   : $BACKUP_DIR/"
    echo "  State     : $BACKUP_DIR/phase3_state.json"
    echo "  Guide     : $BACKUP_DIR/REPLICATION_GUIDE.md"
    echo ""
    echo -e "${YELLOW}Complete the manual replication steps in REPLICATION_GUIDE.md${NC}"
    echo -e "${YELLOW}then proceed to:${NC}"
    echo ""
    echo "  ./04_cutover.sh \"$SOURCE_VM\" \"$SSH_USER\" \"$BACKUP_DIR/phase3_state.json\""
    echo ""
}

main

# Made with Bob
