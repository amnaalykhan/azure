#!/bin/bash

################################################################################
# Approach 1 — Fyre to Azure Migration Orchestrator
#
# Fully automated: SSH into Fyre VM, discover all config, generate Terraform
# vars, deploy Azure infra, backup, restore, validate — zero manual editing.
#
# Pipeline:
#   1. Pre-flight    — tools, Azure login check, SSH test, quota check
#   2. Discover      — SSH into Fyre VM → collect ports, disks, OS, services
#   3. Terraform     — auto-generate terraform.tfvars, plan, apply → Azure infra
#   4. Backup        — tar Fyre VM data → download → upload to Azure Storage
#   5. Configure     — format data disk, install packages on Azure VM
#   6. Restore       — download backups from Azure Storage → extract on Azure VM
#   7. Network       — set hostname, hosts file, firewall
#   8. Validate      — post-migration validation checks
#   9. Report        — full migration report
#
# Usage:
#   ./migrate_any_fyre_vm.sh <vm-ip-or-hostname> \
#       --subscription <SUB_ID> \
#       --tenant       <TENANT_ID> \
#       [--user        <ssh-user>]     default: root
#       [--password    <ssh-pass>]     omit if using SSH key
#       [--yes]                        skip confirmation prompt
#
# Examples:
#   ./migrate_any_fyre_vm.sh 9.46.106.146 \
#       --subscription abc123 --tenant xyz456 --password MyP@ss
#
#   ./migrate_any_fyre_vm.sh myvm.fyre.ibm.com \
#       --subscription abc123 --tenant xyz456 --yes
################################################################################

set -euo pipefail

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

# ── Argument parsing ───────────────────────────────────────────────────────────
FYRE_VM="${1:-}"
SSH_USER="root"
SSH_PASS=""
SUBSCRIPTION_ID=""
TENANT_ID=""
AUTO_YES=false

shift || true   # shift past positional $1 (the VM address)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --subscription) SUBSCRIPTION_ID="$2"; shift 2 ;;
        --tenant)       TENANT_ID="$2";       shift 2 ;;
        --user)         SSH_USER="$2";         shift 2 ;;
        --password)     SSH_PASS="$2";         shift 2 ;;
        --yes)          AUTO_YES=true;         shift   ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
WORK_DIR="${SCRIPT_DIR}/migration_${TIMESTAMP}"
LOG_FILE="$WORK_DIR/migration.log"
BACKUP_DIR="$WORK_DIR/backup"
DISCOVERY_DIR=""
AZURE_VM_IP=""
AZURE_STORAGE_ACCOUNT=""
AZURE_RG=""
WORKING_REGION=""
AZURE_ADMIN="azureuser"
MY_PUBLIC_IP=""
SSH_KEY_PATH=""

# Create work dir immediately so tlog() can write before preflight() runs
mkdir -p "$WORK_DIR" "$BACKUP_DIR"

# ── SSH helpers ────────────────────────────────────────────────────────────────
ssh_src() {
    if [[ -n "$SSH_PASS" ]]; then
        sshpass -p "$SSH_PASS" ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null "${SSH_USER}@${FYRE_VM}" "$@"
    else
        ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no \
            "${SSH_USER}@${FYRE_VM}" "$@"
    fi
}
ssh_src_safe() { ssh_src "$@" 2>/dev/null || echo ""; }

scp_from_src() {
    if [[ -n "$SSH_PASS" ]]; then
        sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"
    else
        scp -o StrictHostKeyChecking=no "$@"
    fi
}

ssh_az()      { ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no "${AZURE_ADMIN}@${AZURE_VM_IP}" "$@"; }
ssh_az_safe() { ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no "${AZURE_ADMIN}@${AZURE_VM_IP}" "$@" 2>/dev/null || echo ""; }

# ── Logging ────────────────────────────────────────────────────────────────────
tlog()    { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
header()  { echo -e "\n${CYAN}══════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"; tlog "=== $* ==="; }
section() { echo -e "\n${BLUE}── $* ──${NC}"; tlog "-- $* --"; }
ok()      { echo -e "${GREEN}✓${NC} $*"; tlog "✓ $*"; }
info()    { echo -e "${BLUE}ℹ${NC} $*"; tlog "ℹ $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; tlog "⚠ $*"; }
die()     { echo -e "${RED}✗ FATAL:${NC} $*"; tlog "✗ $*"; exit 1; }
confirm() {
    if [[ "$AUTO_YES" == "true" ]]; then
        info "Auto-confirming: $*"
        return 0
    fi
    echo -e "${YELLOW}$*${NC}"
    read -rp "Continue? (yes/no): " a
    [[ "$a" =~ ^[Yy][Ee][Ss]$ ]] || { warn "Cancelled."; exit 0; }
}

################################################################################
# Phase 1 — Pre-flight
################################################################################

preflight() {
    header "Phase 1 — Pre-flight Checks"

    [[ -z "$FYRE_VM" ]] && {
        echo ""
        echo "Usage: $0 <vm-ip-or-hostname> --subscription <ID> --tenant <ID> [options]"
        echo ""
        echo "Required:"
        echo "  --subscription <ID>   Azure Subscription ID"
        echo "  --tenant       <ID>   Azure Tenant ID"
        echo ""
        echo "Optional:"
        echo "  --user     <user>     SSH user on Fyre VM  (default: root)"
        echo "  --password <pass>     SSH password         (omit for key auth)"
        echo "  --yes                 Skip confirmation prompt"
        echo ""
        echo "Example:"
        echo "  $0 9.46.106.146 --subscription abc123 --tenant xyz456 --password MyP@ss --yes"
        exit 1
    }

    [[ -z "$SUBSCRIPTION_ID" ]] && die "--subscription <ID> is required. Get it from: az account show --query id -o tsv"
    [[ -z "$TENANT_ID"       ]] && die "--tenant <ID> is required.       Get it from: az account show --query tenantId -o tsv"

    mkdir -p "$WORK_DIR" "$BACKUP_DIR"

    # Tools
    for tool in az terraform jq ssh curl; do
        command -v "$tool" &>/dev/null && ok "$tool installed" || die "$tool not installed. See README for install instructions."
    done
    if [[ -n "$SSH_PASS" ]]; then
        command -v sshpass &>/dev/null && ok "sshpass installed" \
            || die "sshpass not installed. Fix: brew install sshpass"
    fi

    # Azure login check
    section "Azure authentication"
    az account show &>/dev/null || die "Not logged into Azure. Run: az login"
    AZ_ACCOUNT=$(az account show --query "{name:name,id:id}" -o tsv | tr '\t' ' / ')
    ok "Azure authenticated: $AZ_ACCOUNT"

    # Detect your public IP for SSH CIDR (auto — no manual editing needed)
    # Use ipv4.* endpoints to force IPv4 — Azure NSG rules do not accept IPv6 prefixes
    section "Detecting public IP for SSH CIDR"
    MY_PUBLIC_IP=$(curl -fsSL --max-time 5 https://ipv4.icanhazip.com 2>/dev/null \
        || curl -fsSL --max-time 5 https://api4.ipify.org 2>/dev/null \
        || curl -fsSL --max-time 5 https://ipv4bot.whatismyipaddress.com 2>/dev/null \
        || echo "")
    # If we still got an IPv6 address (contains ':'), fall back to open CIDR
    if [[ "$MY_PUBLIC_IP" == *:* ]]; then
        warn "Detected IPv6 address ($MY_PUBLIC_IP) — Azure NSG requires IPv4, using 0.0.0.0/0"
        MY_PUBLIC_IP="0.0.0.0"
    fi
    if [[ -n "$MY_PUBLIC_IP" && "$MY_PUBLIC_IP" != "0.0.0.0" ]]; then
        ok "Your public IP: $MY_PUBLIC_IP → allowed_ssh_cidr = ${MY_PUBLIC_IP}/32"
    else
        warn "Could not auto-detect IPv4 — will use 0.0.0.0/0 for SSH CIDR (restrict manually after deploy)"
        MY_PUBLIC_IP="0.0.0.0"
    fi

    # Detect SSH public key (auto — no manual path needed)
    section "Detecting SSH public key"
    SSH_KEY_PATH=""
    # Azure only supports RSA keys — check RSA first
    for candidate in ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub ~/.ssh/id_ed25519.pub; do
        if [[ -f "$candidate" ]]; then
            SSH_KEY_PATH="$candidate"
            ok "SSH public key found: $SSH_KEY_PATH"
            break
        fi
    done
    if [[ -z "$SSH_KEY_PATH" ]]; then
        info "No RSA SSH key found — generating RSA 4096 key pair at ~/.ssh/id_rsa"
        ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -C "fyre-migration" &>/dev/null
        SSH_KEY_PATH=~/.ssh/id_rsa.pub
        ok "SSH key generated: $SSH_KEY_PATH"
    fi

    # SSH to source VM
    section "SSH connection to Fyre VM"
    info "Testing SSH to ${SSH_USER}@${FYRE_VM}..."
    if ssh_src "echo ok" &>/dev/null; then
        ok "SSH connection successful (auth: $([ -n "$SSH_PASS" ] && echo password || echo key))"
    else
        die "Cannot SSH to ${SSH_USER}@${FYRE_VM}
  With password : add --password <your-fyre-vm-password>
  With key auth : register ~/.ssh/id_ed25519.pub on the VM via Fyre portal"
    fi

    # vCore quota check — try candidate regions, pick first with enough quota
    section "Azure quota check"
    info "Checking available vCores across regions..."
    CANDIDATES=(southeastasia centralindia eastus canadacentral northeurope)
    for region in "${CANDIDATES[@]}"; do
        QUOTA=$(az vm list-usage --location "$region" \
            --query "[?name.value=='cores'].{used:currentValue,limit:limit}" \
            -o tsv 2>/dev/null | awk '{avail=$2-$1; print avail}' || echo "0")
        if [[ "${QUOTA:-0}" -ge 4 ]]; then
            WORKING_REGION="$region"
            ok "Region '$region': $QUOTA vCores available — selected"
            break
        else
            warn "Region '$region': ${QUOTA:-0} free vCores (need ≥4, skipping)"
        fi
    done
    [[ -n "$WORKING_REGION" ]] || die "No region with ≥4 free vCores found. Request a quota increase: https://portal.azure.com/#blade/Microsoft_Azure_Capacity/QuotaMenuBlade"

    tlog "Migration started: vm=$FYRE_VM user=$SSH_USER region=$WORKING_REGION sub=$SUBSCRIPTION_ID"
}

################################################################################
# Phase 2 — Discovery
################################################################################

run_discovery() {
    header "Phase 2 — Source VM Discovery"

    [[ -f "$SCRIPT_DIR/discover_fyre_network.sh" ]] || die "discover_fyre_network.sh not found in $SCRIPT_DIR"
    chmod +x "$SCRIPT_DIR/discover_fyre_network.sh"

    local pass_arg=""
    [[ -n "$SSH_PASS" ]] && pass_arg="--password $SSH_PASS"

    info "Running discover_fyre_network.sh..."
    # discover_fyre_network.sh expects <user@host|host> as a single argument
    local target="${SSH_USER}@${FYRE_VM}"
    # shellcheck disable=SC2086
    "$SCRIPT_DIR/discover_fyre_network.sh" "$target" $pass_arg 2>&1 | tee -a "$LOG_FILE"

    DISCOVERY_DIR=$(ls -dt "$SCRIPT_DIR"/fyre_discovery_* 2>/dev/null | head -1 || echo "")
    [[ -d "$DISCOVERY_DIR" ]] || die "Discovery directory not found — Phase 2 failed"

    ok "Discovery complete: $DISCOVERY_DIR"

    # Copy the NSG rules JSON into azure_terraform/ so dynamic_nsg.tf can read it
    if [[ -f "$DISCOVERY_DIR/azure_nsg_rules.json" ]]; then
        cp "$DISCOVERY_DIR/azure_nsg_rules.json" "$SCRIPT_DIR/azure_terraform/discovered_nsg_rules.json"
        ok "NSG rules copied to azure_terraform/discovered_nsg_rules.json"
    else
        warn "No azure_nsg_rules.json found in discovery output — dynamic NSG rules will not be applied"
    fi

    # Show summary
    info "Source VM profile:"
    jq -r '"  Hostname : \(.hostname)\n  OS       : \(.os)\n  vCPUs    : \(.vcpus)\n  Memory   : \(.memory_gb)GB\n  Disk     : \(.disk_total_gb)GB"' \
        "$DISCOVERY_DIR/vm_resources.json" 2>/dev/null || true
    echo "  TCP ports: $(jq -r '.tcp[].port' "$DISCOVERY_DIR/listening_ports.json" 2>/dev/null | tr '\n' ' ')"
}

################################################################################
# Phase 3 — Terraform: update vars + apply
################################################################################

deploy_azure_infra() {
    header "Phase 3 — Deploy Azure Infrastructure (Terraform)"

    TF_DIR="$SCRIPT_DIR/azure_terraform"
    [[ -d "$TF_DIR" ]] || die "azure_terraform directory not found at $TF_DIR"

    # ── Read discovered VM sizing ──────────────────────────────────────────────
    DISC_VM_SIZE="Standard_D4s_v3"
    DISC_OS_DISK=64
    DISC_DATA_DISK=32
    DISC_PROJECT_NAME="fyremigration"

    if [[ -f "$DISCOVERY_DIR/terraform_vars.auto.tfvars" ]]; then
        v=$(grep '^vm_size'           "$DISCOVERY_DIR/terraform_vars.auto.tfvars" | cut -d'"' -f2);  [[ -n "$v" ]] && DISC_VM_SIZE="$v"
        v=$(grep '^os_disk_size_gb'   "$DISCOVERY_DIR/terraform_vars.auto.tfvars" | awk '{print $3}'); [[ -n "$v" ]] && DISC_OS_DISK="$v"
        v=$(grep '^data_disk_size_gb' "$DISCOVERY_DIR/terraform_vars.auto.tfvars" | awk '{print $3}'); [[ -n "$v" ]] && DISC_DATA_DISK="$v"
        v=$(grep '^project_name'      "$DISCOVERY_DIR/terraform_vars.auto.tfvars" | cut -d'"' -f2);  [[ -n "$v" ]] && DISC_PROJECT_NAME="$v"
    fi

    # Cap VM size to 4 vCores max — student subscriptions typically have 6 vCore quota
    # Standard_D8s_v3 = 8 cores (too large), Standard_D4s_v3 = 4 cores (fits)
    case "$DISC_VM_SIZE" in
        *D8s*|*D16s*|*D32s*|*E8s*|*E16s*|*F8s*|*F16s*)
            warn "VM size $DISC_VM_SIZE requires >6 vCores — downscaling to Standard_D4s_v3"
            DISC_VM_SIZE="Standard_D4s_v3" ;;
    esac

    # ── Auto-generate terraform.tfvars — no manual editing required ────────────
    section "Generating terraform.tfvars from discovered values"
    cat > "$TF_DIR/terraform.tfvars" <<TFVARS
# Auto-generated by migrate_any_fyre_vm.sh on $(date)
# Source VM : ${SSH_USER}@${FYRE_VM}
# Do not edit — re-running the script will regenerate this file

# ── Azure identity (provided via --subscription / --tenant flags) ─────────────
subscription_id = "${SUBSCRIPTION_ID}"
tenant_id       = "${TENANT_ID}"

# ── Infrastructure ────────────────────────────────────────────────────────────
location             = "${WORKING_REGION}"
project_name         = "${DISC_PROJECT_NAME}"
resource_group_name  = "rg-${DISC_PROJECT_NAME}-migration"

# ── VM sizing (auto-sized from discovered Fyre VM specs) ──────────────────────
vm_size           = "${DISC_VM_SIZE}"
os_disk_size_gb   = ${DISC_OS_DISK}
data_disk_size_gb = ${DISC_DATA_DISK}

# ── SSH access ────────────────────────────────────────────────────────────────
ssh_public_key_path = "${SSH_KEY_PATH}"
allowed_ssh_cidr    = "${MY_PUBLIC_IP}/32"

# ── Features ─────────────────────────────────────────────────────────────────
create_public_ip = true
enable_backup    = true
TFVARS

    ok "terraform.tfvars generated:"
    info "  subscription_id  = ${SUBSCRIPTION_ID}"
    info "  tenant_id        = ${TENANT_ID}"
    info "  location         = ${WORKING_REGION}"
    info "  vm_size          = ${DISC_VM_SIZE}"
    info "  os_disk_size_gb  = ${DISC_OS_DISK}"
    info "  allowed_ssh_cidr = ${MY_PUBLIC_IP}/32"

    cd "$TF_DIR"

    # Remove stale plan so terraform always re-plans with current tfvars
    rm -f tfplan

    section "terraform init"
    terraform init -upgrade 2>&1 | tee -a "$LOG_FILE"

    section "terraform plan"
    terraform plan -out=tfplan 2>&1 | tee -a "$LOG_FILE"

    confirm "Deploy the Azure infrastructure shown above?"

    section "terraform apply"
    terraform apply -auto-approve tfplan 2>&1 | tee -a "$LOG_FILE"

    # Capture outputs
    AZURE_VM_IP=$(terraform output -raw vm_public_ip 2>/dev/null || echo "")
    AZURE_STORAGE_ACCOUNT=$(terraform output -raw storage_account_name 2>/dev/null || echo "")
    AZURE_RG=$(terraform output -raw resource_group_name 2>/dev/null || echo "")

    cd "$SCRIPT_DIR"

    [[ -n "$AZURE_VM_IP" ]] || die "Could not get Azure VM public IP from Terraform outputs"
    ok "Azure VM deployed: $AZURE_VM_IP"
    ok "Storage account  : $AZURE_STORAGE_ACCOUNT"
    ok "Resource group   : $AZURE_RG"
}

################################################################################
# Phase 4 — Backup source VM
################################################################################

backup_source_vm() {
    header "Phase 4 — Backup Source VM"

    VM_HOSTNAME=$(ssh_src_safe "hostname")
    REMOTE_STAGE="/tmp/azure_migration_backup_${TIMESTAMP}"

    section "Creating backup on source VM"
    ssh_src "mkdir -p $REMOTE_STAGE"

    # System config — always useful on any VM
    info "Backing up /etc config files..."
    ssh_src "tar czf $REMOTE_STAGE/etc_config.tar.gz \
        /etc/hosts /etc/hostname /etc/fstab /etc/resolv.conf \
        /etc/nsswitch.conf /etc/sysctl.conf /etc/environment \
        /etc/profile.d/ /etc/cron.d/ /etc/cron.daily/ \
        /etc/security/limits.conf \
        2>/dev/null || true"
    ok "System config backed up"

    # Home directories
    info "Backing up /home..."
    ssh_src "tar czf $REMOTE_STAGE/home_backup.tar.gz /home/ 2>/dev/null || true"
    ok "Home directories backed up"

    # Application data — back up whatever standard dirs exist
    info "Discovering application directories..."
    APP_DIRS=$(ssh_src_safe "for d in /opt /srv /data /app /var/app /var/data; do [ -d \"\$d\" ] && echo \$d; done")
    if [[ -n "$APP_DIRS" ]]; then
        info "Found: $APP_DIRS"
        # shellcheck disable=SC2086
        ssh_src "tar czf $REMOTE_STAGE/app_data.tar.gz $APP_DIRS 2>/dev/null || true"
        ok "Application data backed up"
    else
        warn "No standard app directories found (/opt, /srv, /data, /app)"
    fi

    # Systemd service files (custom ones only — not distro defaults)
    info "Backing up systemd service files..."
    ssh_src "tar czf $REMOTE_STAGE/systemd_services.tar.gz \
        /etc/systemd/system/ 2>/dev/null || true"
    ok "Service files backed up"

    # SSH configuration
    info "Backing up SSH config..."
    ssh_src "tar czf $REMOTE_STAGE/ssh_config.tar.gz \
        /etc/ssh/sshd_config /root/.ssh/ 2>/dev/null || true"
    ok "SSH config backed up"

    # System snapshot (text — quick reference)
    info "Capturing system snapshot..."
    ssh_src "
        {
            echo '=== HOSTNAME ==='; hostname -f
            echo '=== OS ==='; cat /etc/os-release
            echo '=== DISKS ==='; lsblk; df -h
            echo '=== MEMORY ==='; free -h
            echo '=== NETWORK ==='; ip addr; ip route
            echo '=== SERVICES ==='; systemctl list-units --type=service --state=running --no-legend
            echo '=== PORTS ==='; ss -tlnp
            echo '=== USERS ==='; cat /etc/passwd
        } > $REMOTE_STAGE/system_snapshot.txt 2>/dev/null || true
    "
    ok "System snapshot captured"

    # Download all backups
    section "Downloading backups to local machine"
    scp_from_src -r "${SSH_USER}@${FYRE_VM}:${REMOTE_STAGE}/" "$BACKUP_DIR/" 2>/dev/null || \
        die "Failed to download backups from source VM"
    ok "Backups downloaded to: $BACKUP_DIR/"
    info "Size: $(du -sh "$BACKUP_DIR" | cut -f1)"

    # Clean up remote stage
    ssh_src "rm -rf $REMOTE_STAGE" 2>/dev/null || true
}

################################################################################
# Phase 5 — Upload to Azure Storage
################################################################################

upload_to_azure() {
    header "Phase 5 — Upload Backups to Azure Storage"

    [[ -z "$AZURE_STORAGE_ACCOUNT" ]] && die "Storage account name not set"

    STORAGE_KEY=$(az storage account keys list \
        --resource-group "$AZURE_RG" \
        --account-name "$AZURE_STORAGE_ACCOUNT" \
        --query "[0].value" -o tsv)

    # Create migration-files container
    az storage container create \
        --account-name "$AZURE_STORAGE_ACCOUNT" \
        --account-key "$STORAGE_KEY" \
        --name "migration-files" \
        --auth-mode key \
        --output none 2>/dev/null || true

    info "Uploading to migration-files container..."
    # Use "*.tar.gz" not "**/*.tar.gz" — backup files are directly in BACKUP_DIR,
    # not in subdirectories. The ** glob is not supported by all az CLI versions.
    az storage blob upload-batch \
        --account-name "$AZURE_STORAGE_ACCOUNT" \
        --account-key "$STORAGE_KEY" \
        --destination "migration-files" \
        --source "$BACKUP_DIR" \
        --pattern "*.tar.gz" \
        --overwrite true \
        --output none 2>/dev/null && ok "tar.gz archives uploaded" || warn "Some files may not have uploaded"

    ok "Backups available in Azure Storage: $AZURE_STORAGE_ACCOUNT/migration-files"
}

################################################################################
# Phase 6 — Configure Azure VM
################################################################################

configure_azure_vm() {
    header "Phase 6 — Configure Azure VM"

    # Wait for SSH
    info "Waiting for SSH on Azure VM ($AZURE_VM_IP)..."
    for i in {1..30}; do
        if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
                "${AZURE_ADMIN}@${AZURE_VM_IP}" "echo ready" &>/dev/null; then
            ok "SSH ready on Azure VM"
            break
        fi
        [[ $i -eq 30 ]] && die "Azure VM SSH not ready after 5 minutes"
        info "  Waiting... ($i/30)"; sleep 10
    done

    # Install base packages
    section "Installing base packages"
    ssh_az "
        if command -v dnf &>/dev/null; then
            sudo dnf install -y wget curl tar gzip rsync net-tools bind-utils jq 2>/dev/null || true
        elif command -v apt-get &>/dev/null; then
            sudo apt-get install -y -q wget curl tar gzip rsync net-tools dnsutils jq 2>/dev/null || true
        fi
    " && ok "Base packages installed" || warn "Some packages may not have installed"

    # Format and mount data disk
    section "Data disk setup"
    DATA_DISK=$(ssh_az_safe "lsblk -d -o NAME,TYPE -n 2>/dev/null | awk '\$2==\"disk\" && \$1!=\"sda\" {print \$1}' | head -1")
    if [[ -n "$DATA_DISK" ]]; then
        FS_TYPE=$(ssh_az_safe "lsblk -fn /dev/${DATA_DISK} 2>/dev/null | awk '{print \$2}' | head -1")
        if [[ -z "$FS_TYPE" ]]; then
            info "Formatting /dev/${DATA_DISK} as ext4..."
            ssh_az "
                sudo parted /dev/${DATA_DISK} --script mklabel gpt
                sudo parted /dev/${DATA_DISK} --script mkpart primary ext4 0% 100%
                sleep 2
                sudo mkfs.ext4 -F /dev/${DATA_DISK}1
                sudo mkdir -p /data
                echo '/dev/${DATA_DISK}1 /data ext4 defaults 0 0' | sudo tee -a /etc/fstab
                sudo mount -a
                sudo chmod 755 /data
            " && ok "Data disk formatted and mounted at /data" || warn "Data disk setup had errors"
        else
            warn "Disk /dev/${DATA_DISK} already has filesystem: $FS_TYPE — skipping format"
        fi
    else
        warn "No additional data disk detected — data will be on OS disk"
        ssh_az "sudo mkdir -p /data" 2>/dev/null || true
    fi
}

################################################################################
# Phase 7 — Restore data from Azure Storage onto Azure VM
################################################################################

restore_data() {
    header "Phase 7 — Restore Data on Azure VM"

    STORAGE_KEY=$(az storage account keys list \
        --resource-group "$AZURE_RG" \
        --account-name "$AZURE_STORAGE_ACCOUNT" \
        --query "[0].value" -o tsv)

    # List blobs
    BLOBS=$(az storage blob list \
        --account-name "$AZURE_STORAGE_ACCOUNT" \
        --account-key "$STORAGE_KEY" \
        --container-name "migration-files" \
        --query "[?ends_with(name,'.tar.gz')].name" \
        -o tsv 2>/dev/null || echo "")

    if [[ -z "$BLOBS" ]]; then
        warn "No backup archives found in Azure Storage — skipping restore"
        return
    fi

    info "Backups to restore:"
    echo "$BLOBS" | while read -r b; do echo "  - $b"; done

    # Generate SAS token so Azure VM can download directly (no az CLI on Azure VM needed)
    SAS_EXPIRY=$(date -u -v+2H '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -d '+2 hours' '+%Y-%m-%dT%H:%MZ' 2>/dev/null || echo "")
    SAS_TOKEN=""
    if [[ -n "$SAS_EXPIRY" ]]; then
        SAS_TOKEN=$(az storage account generate-sas \
            --account-name "$AZURE_STORAGE_ACCOUNT" \
            --account-key "$STORAGE_KEY" \
            --expiry "$SAS_EXPIRY" \
            --permissions rl \
            --resource-types co \
            --services b \
            --output tsv 2>/dev/null || echo "")
    fi

    ssh_az "sudo mkdir -p /tmp/migration_restore && sudo chmod 777 /tmp/migration_restore"

    # Download each archive onto the Azure VM
    echo "$BLOBS" | while read -r blob; do
        [[ -z "$blob" ]] && continue
        fname=$(basename "$blob")
        URL="https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/migration-files/${blob}"
        if [[ -n "$SAS_TOKEN" ]]; then
            ssh_az "curl -fsSL '${URL}?${SAS_TOKEN}' -o /tmp/migration_restore/${fname}" \
                && ok "  Downloaded: $fname" || warn "  Failed: $fname"
        else
            # Fallback: direct SCP from local backup
            scp -o StrictHostKeyChecking=no "$BACKUP_DIR/${fname}" \
                "${AZURE_ADMIN}@${AZURE_VM_IP}:/tmp/migration_restore/" 2>/dev/null \
                && ok "  Copied: $fname" || warn "  Could not copy: $fname"
        fi
    done

    # Extract each archive in the right place
    section "Extracting archives on Azure VM"
    ssh_az '
        set -e
        cd /tmp/migration_restore

        [ -f etc_config.tar.gz ]       && { echo "Restoring /etc config...";        sudo tar xzf etc_config.tar.gz       -C /          2>/dev/null || true; }
        [ -f home_backup.tar.gz ]      && { echo "Restoring /home...";              sudo tar xzf home_backup.tar.gz      -C /          2>/dev/null || true; }
        [ -f app_data.tar.gz ]         && { echo "Restoring application data...";   sudo tar xzf app_data.tar.gz         -C /          2>/dev/null || true; }
        [ -f systemd_services.tar.gz ] && { echo "Restoring service files...";      sudo tar xzf systemd_services.tar.gz -C /tmp/svc   2>/dev/null || true
                                             sudo cp -rn /tmp/svc/etc/systemd/system/*.service /etc/systemd/system/ 2>/dev/null || true; }
        [ -f ssh_config.tar.gz ]       && { echo "Restoring SSH config...";         sudo tar xzf ssh_config.tar.gz       -C /tmp/ssh   2>/dev/null || true
                                             # Restore only authorized_keys, not sshd_config (keep Azure default)
                                             sudo cp /tmp/ssh/root/.ssh/authorized_keys /home/azureuser/.ssh/ 2>/dev/null || true; }
        sudo restorecon -r /home/ /opt/ 2>/dev/null || true
        sudo systemctl daemon-reload   2>/dev/null || true
        echo "Restore complete"
    ' && ok "All archives restored" || warn "Some restore steps had errors"
}

################################################################################
# Phase 8 — Network configuration on Azure VM
################################################################################

configure_networking() {
    header "Phase 8 — Network Configuration"

    # system_snapshot.txt is downloaded directly into $BACKUP_DIR (not a sub-subdirectory)
    SOURCE_HOSTNAME=$(grep -A1 '=== HOSTNAME ===' "$BACKUP_DIR/system_snapshot.txt" 2>/dev/null \
        | tail -1 | xargs || \
        ssh_az_safe "hostname" || echo "$FYRE_VM")

    section "Hostname"
    ssh_az "sudo hostnamectl set-hostname '${SOURCE_HOSTNAME}'" \
        && ok "Hostname set: $SOURCE_HOSTNAME" || warn "Could not set hostname"

    section "Hosts file"
    ssh_az "
        grep -q '127.0.0.1' /etc/hosts || echo '127.0.0.1 localhost' | sudo tee -a /etc/hosts
        grep -q '${SOURCE_HOSTNAME}' /etc/hosts || echo \"127.0.1.1 ${SOURCE_HOSTNAME}\" | sudo tee -a /etc/hosts
    " && ok "Hosts file updated" || warn "Could not update hosts file"

    section "Firewall"
    FW_TYPE=$(jq -r '.type' "$DISCOVERY_DIR/firewall.json" 2>/dev/null || echo "none")
    if [[ "$FW_TYPE" == "firewalld" ]]; then
        ssh_az "sudo systemctl enable --now firewalld 2>/dev/null || true" \
            && ok "firewalld enabled" || warn "Could not enable firewalld"
    fi

    ssh_az "sudo systemctl daemon-reload 2>/dev/null || true"
    ok "Network configuration applied"
}

################################################################################
# Phase 9 — Validate
################################################################################

validate_migration() {
    header "Phase 9 — Post-Migration Validation"

    PASS=0; FAIL=0; WARN=0

    p() { echo -e "${GREEN}✓${NC} $*"; ((PASS++)); tlog "PASS: $*"; }
    f() { echo -e "${RED}✗${NC} $*"; ((FAIL++)); tlog "FAIL: $*"; }
    w() { echo -e "${YELLOW}⚠${NC} $*"; ((WARN++)); tlog "WARN: $*"; }

    section "Azure VM status"
    POWER=$(az vm show --resource-group "$AZURE_RG" --name "$(az vm list -g "$AZURE_RG" --query "[0].name" -o tsv 2>/dev/null)" \
        --show-details --query powerState -o tsv 2>/dev/null || echo "")
    [[ "$POWER" == "VM running" ]] && p "VM is running" || f "VM not running (state: ${POWER:-unknown})"

    section "Network"
    if [[ -n "$AZURE_VM_IP" ]]; then
        p "Public IP assigned: $AZURE_VM_IP"
        timeout 5 bash -c "echo > /dev/tcp/$AZURE_VM_IP/22" 2>/dev/null && p "Port 22 reachable" || w "Port 22 not reachable"
    else
        f "No public IP"
    fi

    section "SSH & OS"
    if ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no \
            "${AZURE_ADMIN}@${AZURE_VM_IP}" "echo ok" &>/dev/null; then
        p "SSH connection successful (key auth)"
        REMOTE_HOSTNAME=$(ssh_az_safe "hostname")
        p "Remote hostname: $REMOTE_HOSTNAME"
        OS=$(ssh_az_safe "cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'\"' -f2")
        info "OS: $OS"
        UPTIME=$(ssh_az_safe "uptime -p 2>/dev/null || uptime")
        info "Uptime: $UPTIME"
    else
        f "Cannot SSH to ${AZURE_ADMIN}@${AZURE_VM_IP}"
    fi

    section "Disk & Data"
    DATA_MNT=$(ssh_az_safe "df -h /data 2>/dev/null | tail -1")
    [[ -n "$DATA_MNT" ]] && p "Data disk mounted: $DATA_MNT" || w "/data not a separate mount"
    ROOT_DISK=$(ssh_az_safe "df -h / | tail -1")
    info "Root disk: $ROOT_DISK"

    section "Critical files"
    for f in /etc/passwd /etc/hosts /etc/fstab; do
        ssh_az_safe "test -f $f && echo yes" | grep -q yes \
            && p "File present: $f" || f "Missing: $f"
    done

    section "Services"
    SVC_COUNT=$(ssh_az_safe "systemctl list-units --type=service --state=running --no-legend 2>/dev/null | wc -l")
    [[ "${SVC_COUNT:-0}" -gt 0 ]] && p "Running services: $SVC_COUNT" || f "No running services"
    SSHD=$(ssh_az_safe "systemctl is-active sshd 2>/dev/null")
    [[ "$SSHD" == "active" ]] && p "sshd: active" || w "sshd: $SSHD"

    section "Security"
    DISABLE_PASS=$(az vm show --resource-group "$AZURE_RG" \
        --name "$(az vm list -g "$AZURE_RG" --query "[0].name" -o tsv 2>/dev/null)" \
        --query "osProfile.linuxConfiguration.disablePasswordAuthentication" -o tsv 2>/dev/null || echo "unknown")
    [[ "$DISABLE_PASS" == "true" ]] && p "Password auth disabled (SSH key only)" || w "Password auth may be enabled"

    section "Cost estimate"
    VM_SIZE=$(az vm list -g "$AZURE_RG" --query "[0].hardwareProfile.vmSize" -o tsv 2>/dev/null || echo "unknown")
    case "$VM_SIZE" in
        *D2s*) COST="~\$70/month" ;;
        *D4s*) COST="~\$140/month" ;;
        *D8s*) COST="~\$280/month" ;;
        *)     COST="see pricing calculator" ;;
    esac
    info "VM size: $VM_SIZE — estimated cost: $COST"
    info "Stop when not in use: az vm deallocate -g $AZURE_RG -n \$(az vm list -g $AZURE_RG --query '[0].name' -o tsv)"

    echo ""
    echo -e "  ${GREEN}Passed${NC}: $PASS  ${YELLOW}Warnings${NC}: $WARN  ${RED}Failed${NC}: $FAIL"
    [[ $FAIL -eq 0 ]] && ok "Migration validated successfully!" || warn "Migration has $FAIL failure(s) — review above"
}

################################################################################
# Phase 10 — Report
################################################################################

generate_report() {
    header "Phase 10 — Migration Report"

    REPORT="$WORK_DIR/MIGRATION_REPORT.md"
    SOURCE_HOSTNAME=$(jq -r '.hostname' "$DISCOVERY_DIR/vm_resources.json" 2>/dev/null || echo "$FYRE_VM")
    VM_OS=$(jq -r '.os' "$DISCOVERY_DIR/vm_resources.json" 2>/dev/null || echo "unknown")
    VM_CPU=$(jq -r '.vcpus' "$DISCOVERY_DIR/vm_resources.json" 2>/dev/null || echo "?")
    VM_MEM=$(jq -r '.memory_gb' "$DISCOVERY_DIR/vm_resources.json" 2>/dev/null || echo "?")
    TCP_PORTS=$(jq -r '.tcp[].port' "$DISCOVERY_DIR/listening_ports.json" 2>/dev/null | tr '\n' ' ')

    cat > "$REPORT" <<EOF
# Migration Report — $SOURCE_HOSTNAME → Azure

**Date:** $(date)
**Source:** ${SSH_USER}@${FYRE_VM}
**Target:** azureuser@${AZURE_VM_IP}
**Region:** $WORKING_REGION
**Log:** $LOG_FILE

---

## Source VM

| Field | Value |
|-------|-------|
| Hostname | $SOURCE_HOSTNAME |
| OS | $VM_OS |
| CPU | ${VM_CPU} vCPUs |
| Memory | ${VM_MEM}GB |
| TCP Ports | $TCP_PORTS |

## Azure VM

| Resource | Value |
|----------|-------|
| Public IP | $AZURE_VM_IP |
| Resource Group | $AZURE_RG |
| Region | $WORKING_REGION |
| Storage Account | $AZURE_STORAGE_ACCOUNT |

## SSH Access

\`\`\`bash
ssh azureuser@${AZURE_VM_IP}
\`\`\`

## Cost Management

\`\`\`bash
# Stop VM (no compute cost while stopped)
az vm deallocate -g $AZURE_RG -n \$(az vm list -g $AZURE_RG --query '[0].name' -o tsv)

# Start VM again
az vm start -g $AZURE_RG -n \$(az vm list -g $AZURE_RG --query '[0].name' -o tsv)

# Destroy everything (when done)
cd azure_terraform && terraform destroy
\`\`\`

## Next Steps

1. Test your applications: \`ssh azureuser@${AZURE_VM_IP}\`
2. Update DNS to point to: ${AZURE_VM_IP}
3. Monitor for 24–48 hours
4. Decommission the Fyre VM once confident
EOF

    ok "Report saved: $REPORT"
    echo ""
    cat "$REPORT"
}

################################################################################
# Main
################################################################################

main() {
    echo -e "${CYAN}"
    cat << "EOF"
╔══════════════════════════════════════════════════════════════╗
║   Approach 1 — Fyre to Azure Migration (Terraform)          ║
║   discover → infra → backup → restore → validate            ║
╚══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"

    preflight
    run_discovery
    deploy_azure_infra
    backup_source_vm
    upload_to_azure
    configure_azure_vm
    restore_data
    configure_networking
    validate_migration
    generate_report

    header "Migration Complete"
    ok "Source   : ${SSH_USER}@${FYRE_VM}"
    ok "Azure VM : azureuser@${AZURE_VM_IP}"
    echo ""
    echo "  ssh azureuser@${AZURE_VM_IP}"
    echo "  Log: $LOG_FILE"
    echo ""
}

main "$@"

# Made with Bob
