#!/bin/bash

################################################################################
# Approach 2 — Master Migration Orchestrator
#
# Runs all 5 phases end-to-end with confirmation gates between phases.
# This is the single entry point — equivalent to how Approach 1 chains
# discover_fyre_network.sh → terraform apply → migrate_fyre_to_azure.sh
#
# Phases:
#   1. Discover   — deep inventory of source VM
#   2. Setup      — Azure infrastructure (VNet, NSG, Storage, Vault, Project)
#   3. Replicate  — backup data, upload to Azure, deploy appliance
#   4. Cutover    — stop source, migrate, restore data, configure VM
#   5. Validate   — comprehensive post-migration validation
#
# Usage:
#   ./migrate.sh <source-vm-hostname> [ssh-user] [azure-location]
#
# Examples:
#   ./migrate.sh itz-693000iler-gw3v1m6w.dev.fyre.ibm.com root eastus
#   ./migrate.sh myvm.on-prem.example.com ubuntu eastus2
#   ./migrate.sh 192.168.1.100 root centralindia
#
# You can also run phases individually:
#   ./01_discover.sh <vm> [user]
#   ./02_setup_azure_migrate.sh <vm> <user> <discovery-dir> [location]
#   ./03_replicate.sh <vm> <user> <resources-manifest>
#   ./04_cutover.sh <vm> <user> <phase3-state>
#   ./05_validate.sh <azure-vm-name> <resource-group> [phase4-state]
################################################################################

set -euo pipefail

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

# ── Arguments ──────────────────────────────────────────────────────────────────
SOURCE_VM="${1:-}"
SSH_USER="${2:-root}"
LOCATION="${3:-eastus}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MIGRATION_LOG="migration_${TIMESTAMP}.log"

# State file — tracks what has run and where outputs are
STATE_FILE="migration_state_${TIMESTAMP}.json"

# ── Helpers ───────────────────────────────────────────────────────────────────

print_banner() {
    clear
    echo -e "${CYAN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║          Approach 2 — Azure Migrate  Complete Migration                  ║
║                                                                           ║
║          Fyre / On-Premise VM  →  Azure  (5-Phase Pipeline)              ║
║                                                                           ║
║    Phase 1: Discover   →  Deep inventory of source VM                    ║
║    Phase 2: Setup      →  Azure VNet, NSG, Storage, Vault, Project       ║
║    Phase 3: Replicate  →  Backup data, upload to Azure, appliance        ║
║    Phase 4: Cutover    →  Migrate, restore, configure, DNS               ║
║    Phase 5: Validate   →  Comprehensive post-migration checks            ║
║                                                                           ║
╚═══════════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

header()  { echo -e "\n${CYAN}══════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"; tee_log "=== $1 ==="; }
ok()      { echo -e "${GREEN}✓${NC} $1"; tee_log "✓ $1"; }
info()    { echo -e "${BLUE}ℹ${NC} $1"; tee_log "ℹ $1"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1"; tee_log "⚠ $1"; }
die()     { echo -e "${RED}✗ FATAL:${NC} $1"; tee_log "✗ $1"; exit 1; }
phase_banner() {
    echo ""
    echo -e "${MAGENTA}╔════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║  $1${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════╝${NC}"
    echo ""
}

tee_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$MIGRATION_LOG"; }

confirm_phase() {
    local phase_num="$1"
    local phase_name="$2"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  Ready to start Phase ${phase_num}: ${phase_name}${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -rp "  Start Phase ${phase_num}? (yes/skip/abort): " ans
    case "$ans" in
        [Yy][Ee][Ss]) return 0 ;;
        [Ss][Kk][Ii][Pp]) warn "Phase ${phase_num} skipped by user"; return 1 ;;
        *) warn "Migration aborted by user"; exit 0 ;;
    esac
}

update_state() {
    local key="$1"
    local value="$2"
    # Create or update state JSON
    if [[ -f "$STATE_FILE" ]]; then
        CURRENT=$(cat "$STATE_FILE")
        echo "$CURRENT" | jq ". + {\"$key\": \"$value\"}" > "$STATE_FILE" 2>/dev/null || \
            echo "{\"$key\": \"$value\"}" > "$STATE_FILE"
    else
        echo "{\"source_vm\": \"$SOURCE_VM\", \"ssh_user\": \"$SSH_USER\", \"location\": \"$LOCATION\", \"$key\": \"$value\"}" > "$STATE_FILE"
    fi
}

################################################################################
# Preflight
################################################################################

preflight() {
    header "Pre-Migration Checks"

    [[ -z "$SOURCE_VM" ]] && {
        echo "Usage: $0 <source-vm-hostname> [ssh-user] [azure-location]"
        echo ""
        echo "Examples:"
        echo "  $0 itz-693000iler-gw3v1m6w.dev.fyre.ibm.com root eastus"
        echo "  $0 myvm.on-prem.example.com ubuntu eastus"
        echo ""
        echo "To run individual phases:"
        echo "  $0/01_discover.sh <vm> [user]"
        echo "  $0/02_setup_azure_migrate.sh <vm> <user> <discovery-dir>"
        echo "  $0/03_replicate.sh <vm> <user> <resources-manifest>"
        echo "  $0/04_cutover.sh <vm> <user> <phase3-state>"
        echo "  $0/05_validate.sh <azure-vm-name> <resource-group> [phase4-state]"
        exit 1
    }

    # Check phase scripts exist
    for script in 01_discover.sh 02_setup_azure_migrate.sh 03_replicate.sh 04_cutover.sh 05_validate.sh; do
        [[ -f "$SCRIPT_DIR/$script" ]] || die "Phase script not found: $SCRIPT_DIR/$script"
        [[ -x "$SCRIPT_DIR/$script" ]] || chmod +x "$SCRIPT_DIR/$script"
    done

    # Check tools
    for tool in az ssh jq; do
        command -v "$tool" &>/dev/null || die "$tool is not installed"
    done

    # Check Azure login
    az account show &>/dev/null || die "Not logged into Azure CLI. Run: az login"
    SUBSCRIPTION=$(az account show --query "[name, id]" -o tsv | tr '\t' ' / ')
    ok "Azure authenticated: $SUBSCRIPTION"

    # Test SSH
    info "Testing SSH to $SOURCE_VM..."
    if ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no \
            "${SSH_USER}@${SOURCE_VM}" "echo ok" &>/dev/null; then
        ok "SSH connection successful"
    else
        die "Cannot SSH to ${SSH_USER}@${SOURCE_VM}. Fix SSH access before continuing."
    fi

    # Show plan
    echo ""
    echo -e "${CYAN}Migration Plan:${NC}"
    echo "  Source VM : $SOURCE_VM (as $SSH_USER)"
    echo "  Target    : Azure $LOCATION"
    echo "  Log       : $MIGRATION_LOG"
    echo "  State     : $STATE_FILE"
    echo ""
    echo -e "${YELLOW}Each phase will ask for confirmation before running.${NC}"
    echo -e "${YELLOW}You can skip individual phases if already completed.${NC}"
    echo ""
    read -rp "Start migration? (yes/no): " confirm
    [[ "$confirm" =~ ^[Yy][Ee][Ss]$ ]] || { warn "Migration cancelled."; exit 0; }

    update_state "started_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    tee_log "Migration started for $SOURCE_VM"
}

################################################################################
# Phase 1: Discovery
################################################################################

run_phase1() {
    phase_banner "Phase 1 of 5 — Deep Discovery"
    confirm_phase 1 "Source VM Discovery" || return 0

    echo ""
    info "Running: ./01_discover.sh $SOURCE_VM $SSH_USER"
    echo ""

    "$SCRIPT_DIR/01_discover.sh" "$SOURCE_VM" "$SSH_USER" 2>&1 | tee -a "$MIGRATION_LOG"

    # Find the discovery directory that was just created
    DISCOVERY_DIR=$(ls -dt discovery_* 2>/dev/null | head -1 || echo "")
    [[ -d "$DISCOVERY_DIR" ]] || die "Discovery directory not found — Phase 1 may have failed"

    ok "Phase 1 complete — discovery in: $DISCOVERY_DIR"
    update_state "discovery_dir" "$DISCOVERY_DIR"
    update_state "phase1_complete" "true"
}

################################################################################
# Phase 2: Azure Infrastructure Setup
################################################################################

run_phase2() {
    phase_banner "Phase 2 of 5 — Azure Infrastructure Setup"
    confirm_phase 2 "Create Azure Resources (VNet, NSG, Storage, Vault)" || return 0

    DISCOVERY_DIR=$(jq -r '.discovery_dir' "$STATE_FILE" 2>/dev/null || ls -dt discovery_* 2>/dev/null | head -1 || echo "")
    [[ -d "$DISCOVERY_DIR" ]] || die "No discovery directory found. Run Phase 1 first."

    echo ""
    info "Running: ./02_setup_azure_migrate.sh $SOURCE_VM $SSH_USER $DISCOVERY_DIR $LOCATION"
    echo ""

    "$SCRIPT_DIR/02_setup_azure_migrate.sh" "$SOURCE_VM" "$SSH_USER" "$DISCOVERY_DIR" "$LOCATION" 2>&1 | tee -a "$MIGRATION_LOG"

    # Find the setup output directory
    SETUP_DIR=$(ls -dt azure_setup_* 2>/dev/null | head -1 || echo "")
    [[ -d "$SETUP_DIR" ]] || die "Setup directory not found — Phase 2 may have failed"

    RESOURCES_FILE="$SETUP_DIR/created_resources.json"
    [[ -f "$RESOURCES_FILE" ]] || die "Resources manifest not found: $RESOURCES_FILE"

    ok "Phase 2 complete — resources manifest: $RESOURCES_FILE"
    update_state "setup_dir" "$SETUP_DIR"
    update_state "resources_file" "$RESOURCES_FILE"
    update_state "phase2_complete" "true"
}

################################################################################
# Phase 3: Backup + Replication
################################################################################

run_phase3() {
    phase_banner "Phase 3 of 5 — Backup & Replication"
    confirm_phase 3 "Backup source VM, upload to Azure, deploy appliance" || return 0

    RESOURCES_FILE=$(jq -r '.resources_file' "$STATE_FILE" 2>/dev/null || \
        find . -name "created_resources.json" -newer "$MIGRATION_LOG" 2>/dev/null | head -1 || echo "")
    [[ -f "$RESOURCES_FILE" ]] || die "Resources manifest not found. Run Phase 2 first."

    echo ""
    info "Running: ./03_replicate.sh $SOURCE_VM $SSH_USER $RESOURCES_FILE"
    echo ""

    "$SCRIPT_DIR/03_replicate.sh" "$SOURCE_VM" "$SSH_USER" "$RESOURCES_FILE" 2>&1 | tee -a "$MIGRATION_LOG"

    # Find phase3 state
    BACKUP_DIR=$(ls -dt backup_* 2>/dev/null | head -1 || echo "")
    PHASE3_STATE="${BACKUP_DIR}/phase3_state.json"
    [[ -f "$PHASE3_STATE" ]] || die "Phase 3 state not found: $PHASE3_STATE"

    ok "Phase 3 complete — backup in: $BACKUP_DIR"
    update_state "backup_dir" "$BACKUP_DIR"
    update_state "phase3_state" "$PHASE3_STATE"
    update_state "phase3_complete" "true"

    # Pause — user needs to complete appliance registration manually
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  ACTION REQUIRED: Complete replication setup before Phase 4${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  1. Connect to appliance (RDP to the appliance IP)"
    echo "  2. Register appliance with Azure Migrate"
    echo "  3. Add source VM credentials"
    echo "  4. Start discovery and wait for completion"
    echo "  5. Start replication and wait for initial sync (1-2 hours)"
    echo ""
    echo "  Full instructions: cat $BACKUP_DIR/REPLICATION_GUIDE.md"
    echo ""
    echo "  When replication shows 'Protected' in Azure Portal, continue."
    echo ""
    read -rp "Replication is complete — continue to Phase 4 Cutover? (yes/no): " rep_done
    [[ "$rep_done" =~ ^[Yy][Ee][Ss]$ ]] || { info "Resume later with: ./04_cutover.sh $SOURCE_VM $SSH_USER $PHASE3_STATE"; exit 0; }
}

################################################################################
# Phase 4: Cutover
################################################################################

run_phase4() {
    phase_banner "Phase 4 of 5 — Production Cutover"

    echo -e "${RED}⚠  This phase stops the source VM and performs the final migration.${NC}"
    echo -e "${RED}⚠  Downtime begins in Phase 4. Ensure you have a maintenance window.${NC}"
    echo ""
    confirm_phase 4 "PRODUCTION CUTOVER — stop source, migrate, restore data" || return 0

    PHASE3_STATE=$(jq -r '.phase3_state' "$STATE_FILE" 2>/dev/null || \
        find . -name "phase3_state.json" -newer "$MIGRATION_LOG" 2>/dev/null | head -1 || echo "")
    [[ -f "$PHASE3_STATE" ]] || die "Phase 3 state not found. Run Phase 3 first."

    echo ""
    info "Running: ./04_cutover.sh $SOURCE_VM $SSH_USER $PHASE3_STATE"
    echo ""

    "$SCRIPT_DIR/04_cutover.sh" "$SOURCE_VM" "$SSH_USER" "$PHASE3_STATE" 2>&1 | tee -a "$MIGRATION_LOG"

    # Find phase4 state
    CUTOVER_DIR=$(ls -dt cutover_* 2>/dev/null | head -1 || echo "")
    PHASE4_STATE="${CUTOVER_DIR}/phase4_state.json"
    [[ -f "$PHASE4_STATE" ]] || die "Phase 4 state not found: $PHASE4_STATE"

    AZURE_VM_NAME=$(jq -r '.azure_vm_name' "$PHASE4_STATE" 2>/dev/null || echo "")
    AZURE_VM_IP=$(jq -r '.azure_vm_ip' "$PHASE4_STATE" 2>/dev/null || echo "")
    RESOURCE_GROUP=$(jq -r '.resource_group' "$PHASE4_STATE" 2>/dev/null || echo "")

    ok "Phase 4 complete"
    update_state "cutover_dir" "$CUTOVER_DIR"
    update_state "phase4_state" "$PHASE4_STATE"
    update_state "azure_vm_name" "$AZURE_VM_NAME"
    update_state "azure_vm_ip" "$AZURE_VM_IP"
    update_state "resource_group" "$RESOURCE_GROUP"
    update_state "phase4_complete" "true"
}

################################################################################
# Phase 5: Validate
################################################################################

run_phase5() {
    phase_banner "Phase 5 of 5 — Post-Migration Validation"
    confirm_phase 5 "Validate migrated VM (VM, network, disk, data, services, security)" || return 0

    AZURE_VM_NAME=$(jq -r '.azure_vm_name' "$STATE_FILE" 2>/dev/null || echo "")
    RESOURCE_GROUP=$(jq -r '.resource_group' "$STATE_FILE" 2>/dev/null || echo "")
    PHASE4_STATE=$(jq -r '.phase4_state' "$STATE_FILE" 2>/dev/null || echo "")

    [[ -n "$AZURE_VM_NAME" ]] || die "Azure VM name not found in state. Run Phase 4 first."
    [[ -n "$RESOURCE_GROUP" ]] || die "Resource group not found in state."

    echo ""
    info "Running: ./05_validate.sh $AZURE_VM_NAME $RESOURCE_GROUP $PHASE4_STATE"
    echo ""

    "$SCRIPT_DIR/05_validate.sh" "$AZURE_VM_NAME" "$RESOURCE_GROUP" "$PHASE4_STATE" 2>&1 | tee -a "$MIGRATION_LOG"

    VALIDATION_DIR=$(ls -dt validation_* 2>/dev/null | head -1 || echo "")
    update_state "validation_dir" "$VALIDATION_DIR"
    update_state "phase5_complete" "true"
    update_state "completed_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

################################################################################
# Final Summary
################################################################################

final_summary() {
    header "Migration Complete"

    AZURE_VM_NAME=$(jq -r '.azure_vm_name' "$STATE_FILE" 2>/dev/null || echo "<unknown>")
    AZURE_VM_IP=$(jq -r '.azure_vm_ip' "$STATE_FILE" 2>/dev/null || echo "<unknown>")
    RESOURCE_GROUP=$(jq -r '.resource_group' "$STATE_FILE" 2>/dev/null || echo "<unknown>")

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Migration Completed Successfully!                            ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Source VM       : $SOURCE_VM"
    echo "  Azure VM        : $AZURE_VM_NAME"
    echo "  Public IP       : $AZURE_VM_IP"
    echo "  Resource Group  : $RESOURCE_GROUP"
    echo ""
    echo "  SSH access      : ssh azureuser@${AZURE_VM_IP}"
    echo ""
    echo "  State file      : $STATE_FILE"
    echo "  Migration log   : $MIGRATION_LOG"
    echo ""
    echo -e "${CYAN}Remaining tasks:${NC}"
    echo "  1. Update DNS to point to: $AZURE_VM_IP"
    echo "  2. Verify application functionality"
    echo "  3. Monitor for 24-48 hours"
    echo "  4. Decommission source Fyre VM"
    echo "  5. Delete the Azure Migrate appliance to save costs:"
    echo "     az vm delete -g $RESOURCE_GROUP -n azure-migrate-appliance --yes"
    echo ""
}

################################################################################
# Main
################################################################################

main() {
    print_banner

    # Make all scripts executable
    chmod +x "$SCRIPT_DIR"/0*.sh 2>/dev/null || true

    preflight
    run_phase1
    run_phase2
    run_phase3
    run_phase4
    run_phase5
    final_summary
}

main "$@"

# Made with Bob
