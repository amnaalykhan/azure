#!/bin/bash

################################################################################
# Approach 2 — Phase 5: Post-Migration Validation
#
# Comprehensive validation of the migrated VM. Checks every dimension:
#   • VM status and power state
#   • Network (public IP, private IP, NSG, SSH connectivity)
#   • Storage (OS disk, data disk, mount points)
#   • Data integrity (key directories, file counts)
#   • Services (expected services running)
#   • Performance baseline (CPU, memory, disk I/O)
#   • Security (SSH key-only auth, NSG rules, boot diagnostics)
#   • Azure Backup status
#   • Cost summary
#
# Usage:
#   ./05_validate.sh <azure-vm-name> <resource-group> [phase4-state]
#
# Example:
#   ./05_validate.sh myvm rg-myvm-migrate cutover_20250101_120000/phase4_state.json
################################################################################

set -euo pipefail

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

# ── Arguments ──────────────────────────────────────────────────────────────────
AZURE_VM_NAME="${1:-}"
RESOURCE_GROUP="${2:-}"
PHASE4_STATE="${3:-}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="validation_${TIMESTAMP}"
LOG_FILE="$LOG_DIR/validation.log"
REPORT_FILE="$LOG_DIR/VALIDATION_REPORT.md"

# Counters
PASSED=0; FAILED=0; WARNINGS=0

# ── Helpers ───────────────────────────────────────────────────────────────────
print_banner() {
    echo -e "${CYAN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║   Approach 2 — Phase 5: Post-Migration Validation            ║
║   VM • Network • Disk • Data • Services • Security • Cost    ║
╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

header()   { echo -e "\n${CYAN}══ $1 ══${NC}" | tee -a "$LOG_FILE"; }
section()  { echo -e "\n${BLUE}── $1 ──${NC}" | tee -a "$LOG_FILE"; }
pass()     { echo -e "${GREEN}✓${NC} $1" | tee -a "$LOG_FILE"; ((PASSED++)); }
fail()     { echo -e "${RED}✗${NC} $1" | tee -a "$LOG_FILE"; ((FAILED++)); }
warning()  { echo -e "${YELLOW}⚠${NC} $1" | tee -a "$LOG_FILE"; ((WARNINGS++)); }
info()     { echo -e "${BLUE}ℹ${NC} $1" | tee -a "$LOG_FILE"; }
step()     { echo -e "${MAGENTA}▶${NC} $1" | tee -a "$LOG_FILE"; }
die()      { echo -e "${RED}✗ FATAL:${NC} $1" | tee -a "$LOG_FILE"; exit 1; }

# Run command on the migrated Azure VM
AZURE_ADMIN="azureuser"
AZURE_VM_IP=""
remote_vm() { ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no "${AZURE_ADMIN}@${AZURE_VM_IP}" "$@" 2>/dev/null; }
remote_vm_safe() { ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no "${AZURE_ADMIN}@${AZURE_VM_IP}" "$@" 2>/dev/null || echo ""; }

################################################################################
# Preflight
################################################################################

preflight() {
    header "Preflight"

    [[ -z "$AZURE_VM_NAME" || -z "$RESOURCE_GROUP" ]] && {
        echo "Usage: $0 <azure-vm-name> <resource-group> [phase4-state]"
        echo "Example: $0 myvm rg-myvm-migrate cutover_20250101/phase4_state.json"
        exit 1
    }

    mkdir -p "$LOG_DIR"

    command -v az &>/dev/null || die "Azure CLI not installed"
    command -v jq &>/dev/null || die "jq not installed"
    az account show &>/dev/null || die "Not logged into Azure. Run: az login"

    # Load phase 4 state if provided
    if [[ -n "$PHASE4_STATE" && -f "$PHASE4_STATE" ]]; then
        AZURE_VM_IP=$(jq -r '.azure_vm_ip' "$PHASE4_STATE" 2>/dev/null || echo "")
        info "Loaded phase 4 state: $PHASE4_STATE"
    fi

    # If no IP yet, look it up
    if [[ -z "$AZURE_VM_IP" || "$AZURE_VM_IP" == "null" ]]; then
        AZURE_VM_IP=$(az vm show \
            --resource-group "$RESOURCE_GROUP" \
            --name "$AZURE_VM_NAME" \
            --show-details \
            --query publicIps -o tsv 2>/dev/null || echo "")
    fi

    info "Validating VM  : $AZURE_VM_NAME"
    info "Resource group : $RESOURCE_GROUP"
    info "Public IP      : ${AZURE_VM_IP:-<none>}"
}

################################################################################
# Check 1: VM Status
################################################################################

check_vm_status() {
    section "VM Status"

    # VM exists?
    if ! az vm show --resource-group "$RESOURCE_GROUP" --name "$AZURE_VM_NAME" &>/dev/null; then
        fail "VM '$AZURE_VM_NAME' does not exist in '$RESOURCE_GROUP'"
        return
    fi
    pass "VM exists: $AZURE_VM_NAME"

    VM_INFO=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$AZURE_VM_NAME" --show-details -o json)

    # Power state
    POWER_STATE=$(echo "$VM_INFO" | jq -r '.powerState' 2>/dev/null || echo "unknown")
    if [[ "$POWER_STATE" == "VM running" ]]; then
        pass "VM is running"
    else
        fail "VM is not running (state: $POWER_STATE)"
    fi

    # VM size
    VM_SIZE=$(echo "$VM_INFO" | jq -r '.hardwareProfile.vmSize' 2>/dev/null || echo "unknown")
    info "VM size     : $VM_SIZE"

    # Location
    LOCATION=$(echo "$VM_INFO" | jq -r '.location' 2>/dev/null || echo "unknown")
    info "Location    : $LOCATION"

    # OS type
    OS_TYPE=$(echo "$VM_INFO" | jq -r '.storageProfile.osDisk.osType' 2>/dev/null || echo "unknown")
    info "OS type     : $OS_TYPE"

    # Boot diagnostics
    BOOT_DIAG=$(echo "$VM_INFO" | jq -r '.diagnosticsProfile.bootDiagnostics.enabled' 2>/dev/null || echo "false")
    if [[ "$BOOT_DIAG" == "true" ]]; then
        pass "Boot diagnostics enabled"
    else
        warning "Boot diagnostics not enabled (recommended)"
    fi
}

################################################################################
# Check 2: Network Configuration
################################################################################

check_network() {
    section "Network Configuration"

    VM_INFO=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$AZURE_VM_NAME" --show-details -o json)

    # Public IP
    PUBLIC_IP=$(echo "$VM_INFO" | jq -r '.publicIps' 2>/dev/null || echo "")
    if [[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "null" ]]; then
        pass "Public IP assigned: $PUBLIC_IP"
    else
        warning "No public IP assigned (may be internal-only)"
    fi

    # Private IP
    PRIVATE_IP=$(echo "$VM_INFO" | jq -r '.privateIps' 2>/dev/null || echo "")
    if [[ -n "$PRIVATE_IP" && "$PRIVATE_IP" != "null" ]]; then
        pass "Private IP assigned: $PRIVATE_IP"
    else
        fail "No private IP assigned"
    fi

    # NIC
    NIC_ID=$(echo "$VM_INFO" | jq -r '.networkProfile.networkInterfaces[0].id' 2>/dev/null || echo "")
    if [[ -n "$NIC_ID" ]]; then
        pass "Network interface configured"
        NIC_NAME=$(basename "$NIC_ID")
        # NSG on NIC
        NSG_ID=$(az network nic show --ids "$NIC_ID" --query "networkSecurityGroup.id" -o tsv 2>/dev/null || echo "")
        if [[ -n "$NSG_ID" ]]; then
            pass "NSG attached to NIC"
        else
            warning "No NSG directly on NIC (may be on subnet)"
        fi
    else
        fail "No network interface found"
    fi

    # SSH port reachable
    if [[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "null" ]]; then
        if timeout 5 bash -c "echo > /dev/tcp/$PUBLIC_IP/22" 2>/dev/null; then
            pass "SSH port 22 reachable"
        else
            warning "SSH port 22 not reachable from here (may be NSG-restricted)"
        fi
    fi
}

################################################################################
# Check 3: Storage / Disks
################################################################################

check_storage() {
    section "Storage Configuration"

    VM_INFO=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$AZURE_VM_NAME" -o json)

    # OS disk
    OS_DISK_NAME=$(echo "$VM_INFO" | jq -r '.storageProfile.osDisk.name' 2>/dev/null || echo "")
    OS_DISK_GB=$(echo "$VM_INFO"   | jq -r '.storageProfile.osDisk.diskSizeGb' 2>/dev/null || echo "0")
    OS_DISK_TYPE=$(echo "$VM_INFO" | jq -r '.storageProfile.osDisk.managedDisk.storageAccountType' 2>/dev/null || echo "unknown")

    if [[ -n "$OS_DISK_NAME" && "$OS_DISK_NAME" != "null" ]]; then
        pass "OS disk: $OS_DISK_NAME (${OS_DISK_GB}GB, $OS_DISK_TYPE)"
    else
        fail "OS disk not found"
    fi

    # Data disks
    DATA_DISK_COUNT=$(echo "$VM_INFO" | jq '.storageProfile.dataDisks | length' 2>/dev/null || echo "0")
    if [[ "$DATA_DISK_COUNT" -gt 0 ]]; then
        pass "Data disks: $DATA_DISK_COUNT attached"
        echo "$VM_INFO" | jq -r '.storageProfile.dataDisks[] | "  - \(.name) (\(.diskSizeGb)GB, \(.managedDisk.storageAccountType // "unknown"))"' 2>/dev/null | tee -a "$LOG_FILE"
    else
        warning "No data disks attached (data is on OS disk)"
    fi
}

################################################################################
# Check 4: SSH Connectivity + OS Checks
################################################################################

check_ssh_and_os() {
    section "SSH Connectivity & OS"

    [[ -z "$AZURE_VM_IP" ]] && {
        warning "No public IP — skipping SSH checks"
        return
    }

    step "Testing SSH connection to $AZURE_VM_IP..."
    if timeout 15 ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no \
            "${AZURE_ADMIN}@${AZURE_VM_IP}" "echo ready" &>/dev/null; then
        pass "SSH connection successful (key-based auth)"
    else
        fail "Cannot SSH to ${AZURE_ADMIN}@${AZURE_VM_IP}"
        warning "Remaining checks that require SSH will be skipped"
        return
    fi

    # Hostname
    REMOTE_HOSTNAME=$(remote_vm_safe "hostname")
    pass "Remote hostname: $REMOTE_HOSTNAME"

    # OS version
    OS_INFO=$(remote_vm_safe "cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'\"' -f2")
    info "OS: $OS_INFO"

    # Kernel
    KERNEL=$(remote_vm_safe "uname -r")
    info "Kernel: $KERNEL"

    # Uptime
    UPTIME=$(remote_vm_safe "uptime -p 2>/dev/null || uptime")
    info "Uptime: $UPTIME"

    # Check /etc/hosts
    HOSTS_OK=$(remote_vm_safe "grep -c 'localhost' /etc/hosts 2>/dev/null || echo 0")
    if [[ "$HOSTS_OK" -gt 0 ]]; then
        pass "/etc/hosts configured"
    else
        warning "/etc/hosts may need attention"
    fi

    # Check /data mount
    DATA_MOUNTED=$(remote_vm_safe "df -h /data 2>/dev/null | tail -1")
    if [[ -n "$DATA_MOUNTED" ]]; then
        pass "Data directory accessible: $DATA_MOUNTED"
    else
        warning "/data directory not found or not a separate mount"
    fi
}

################################################################################
# Check 5: Data Integrity
################################################################################

check_data_integrity() {
    section "Data Integrity"

    [[ -z "$AZURE_VM_IP" ]] && { warning "No public IP — skipping data integrity checks"; return; }
    ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
        "${AZURE_ADMIN}@${AZURE_VM_IP}" "echo test" &>/dev/null || { warning "Cannot SSH — skipping data integrity checks"; return; }

    # Check key directories
    for dir in /etc /home /opt /var/log; do
        COUNT=$(remote_vm_safe "find $dir -maxdepth 1 -type f 2>/dev/null | wc -l")
        if [[ "$COUNT" -gt 0 ]]; then
            pass "Directory $dir: $COUNT files"
        else
            warning "Directory $dir is empty or not accessible"
        fi
    done

    # Check disk usage
    DISK_USAGE=$(remote_vm_safe "df -h / | tail -1")
    info "Root disk usage: $DISK_USAGE"

    # Check for any obviously missing critical files
    for file in /etc/passwd /etc/hosts /etc/fstab; do
        if remote_vm_safe "test -f $file && echo yes" | grep -q yes; then
            pass "Critical file exists: $file"
        else
            fail "Critical file missing: $file"
        fi
    done
}

################################################################################
# Check 6: Services
################################################################################

check_services() {
    section "Services"

    [[ -z "$AZURE_VM_IP" ]] && { warning "No public IP — skipping service checks"; return; }
    ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
        "${AZURE_ADMIN}@${AZURE_VM_IP}" "echo test" &>/dev/null || { warning "Cannot SSH — skipping service checks"; return; }

    # Count running services
    RUNNING_COUNT=$(remote_vm_safe "systemctl list-units --type=service --state=running --no-legend 2>/dev/null | wc -l")
    if [[ "$RUNNING_COUNT" -gt 0 ]]; then
        pass "Running services: $RUNNING_COUNT"
    else
        fail "No running services found"
    fi

    # Check critical Linux services
    for svc in sshd; do
        STATE=$(remote_vm_safe "systemctl is-active $svc 2>/dev/null")
        if [[ "$STATE" == "active" ]]; then
            pass "Service $svc: active"
        else
            warning "Service $svc: $STATE"
        fi
    done

    # Show top services
    info "Running services:"
    remote_vm_safe "systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print \"  \" \$1}' | head -15" | tee -a "$LOG_FILE"
}

################################################################################
# Check 7: Performance Baseline
################################################################################

check_performance() {
    section "Performance Baseline"

    [[ -z "$AZURE_VM_IP" ]] && { warning "No public IP — skipping performance checks"; return; }
    ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
        "${AZURE_ADMIN}@${AZURE_VM_IP}" "echo test" &>/dev/null || { warning "Cannot SSH — skipping performance checks"; return; }

    # CPU
    CPU_COUNT=$(remote_vm_safe "nproc")
    info "CPU cores: $CPU_COUNT"

    # Memory
    MEM_TOTAL=$(remote_vm_safe "free -h | awk '/^Mem:/ {print \$2}'")
    MEM_USED=$(remote_vm_safe  "free -h | awk '/^Mem:/ {print \$3}'")
    MEM_FREE=$(remote_vm_safe  "free -h | awk '/^Mem:/ {print \$4}'")
    if [[ -n "$MEM_TOTAL" ]]; then
        pass "Memory: $MEM_USED used / $MEM_TOTAL total ($MEM_FREE free)"
    else
        warning "Could not check memory"
    fi

    # Load average
    LOAD=$(remote_vm_safe "uptime | awk -F'load average:' '{print \$2}'")
    info "Load average: $LOAD"

    # Disk I/O (quick check)
    DISK_AVAIL=$(remote_vm_safe "df -h / | tail -1 | awk '{print \$4}'")
    info "Root disk available: $DISK_AVAIL"
}

################################################################################
# Check 8: Security
################################################################################

check_security() {
    section "Security"

    VM_INFO=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$AZURE_VM_NAME" -o json)

    # Password auth disabled
    DISABLE_PASS=$(echo "$VM_INFO" | jq -r '.osProfile.linuxConfiguration.disablePasswordAuthentication' 2>/dev/null || echo "unknown")
    if [[ "$DISABLE_PASS" == "true" ]]; then
        pass "Password authentication disabled (SSH keys only)"
    else
        warning "Password authentication may be enabled — disable for production"
    fi

    # NSG check
    NIC_ID=$(echo "$VM_INFO" | jq -r '.networkProfile.networkInterfaces[0].id' 2>/dev/null || echo "")
    if [[ -n "$NIC_ID" && "$NIC_ID" != "null" ]]; then
        NSG_ID=$(az network nic show --ids "$NIC_ID" --query "networkSecurityGroup.id" -o tsv 2>/dev/null || echo "")
        if [[ -n "$NSG_ID" ]]; then
            pass "NSG configured on network interface"
            # Check for overly permissive rules
            ANY_ALLOW=$(az network nsg show --ids "$NSG_ID" \
                --query "securityRules[?access=='Allow' && sourceAddressPrefix=='*' && destinationPortRange=='*']" \
                -o tsv 2>/dev/null | head -1 || echo "")
            [[ -z "$ANY_ALLOW" ]] && pass "No wildcard allow-all rules found" || warning "Wildcard allow-all inbound rule detected — review NSG"
        else
            warning "No NSG on NIC (subnet NSG may apply)"
        fi
    fi

    # Managed disk encryption
    ENCRYPTION=$(echo "$VM_INFO" | jq -r '.storageProfile.osDisk.encryptionSettings.enabled' 2>/dev/null || echo "false")
    if [[ "$ENCRYPTION" == "true" ]]; then
        pass "OS disk encryption enabled"
    else
        warning "OS disk encryption not enabled — consider Azure Disk Encryption for sensitive data"
    fi
}

################################################################################
# Check 9: Azure Backup
################################################################################

check_backup() {
    section "Azure Backup"

    VAULT_NAME=$(az backup vault list \
        --resource-group "$RESOURCE_GROUP" \
        --query "[0].name" -o tsv 2>/dev/null || echo "")

    if [[ -z "$VAULT_NAME" ]]; then
        warning "No Recovery Services Vault found in $RESOURCE_GROUP"
        return
    fi

    PROTECTION_STATE=$(az backup item list \
        --resource-group "$RESOURCE_GROUP" \
        --vault-name "$VAULT_NAME" \
        --query "[?properties.friendlyName=='$AZURE_VM_NAME'].properties.protectionStatus" \
        -o tsv 2>/dev/null | head -1 || echo "")

    if [[ "$PROTECTION_STATE" == "Healthy" ]]; then
        pass "Azure Backup: Healthy (vault: $VAULT_NAME)"
    elif [[ -n "$PROTECTION_STATE" ]]; then
        warning "Azure Backup status: $PROTECTION_STATE"
    else
        warning "Azure Backup not configured — enable in Azure Portal"
        info "  Enable: az backup protection enable-for-vm --resource-group $RESOURCE_GROUP --vault-name $VAULT_NAME --vm $AZURE_VM_NAME --policy-name DefaultPolicy"
    fi
}

################################################################################
# Check 10: Estimated Monthly Cost
################################################################################

check_cost() {
    section "Cost Estimate"

    VM_INFO=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$AZURE_VM_NAME" -o json)
    VM_SIZE=$(echo "$VM_INFO" | jq -r '.hardwareProfile.vmSize' 2>/dev/null || echo "unknown")
    OS_DISK_GB=$(echo "$VM_INFO" | jq -r '.storageProfile.osDisk.diskSizeGb' 2>/dev/null || echo "0")

    info "VM size: $VM_SIZE"

    case "$VM_SIZE" in
        *D2s*) VM_COST="~\$70"; ;;
        *D4s*) VM_COST="~\$140"; ;;
        *D8s*) VM_COST="~\$280"; ;;
        *D16s*) VM_COST="~\$560"; ;;
        *E4s*) VM_COST="~\$155"; ;;
        *E8s*) VM_COST="~\$310"; ;;
        *) VM_COST="see pricing calculator"; ;;
    esac

    echo ""
    echo "  Estimated monthly costs:"
    echo "    VM ($VM_SIZE)     : $VM_COST/month"
    echo "    OS disk (${OS_DISK_GB}GB Premium)  : ~\$$(( OS_DISK_GB / 5 ))/month"
    echo "    Backup            : ~\$10/month"
    echo "    Egress            : ~\$5/month"
    echo ""
    echo "  To stop billing when not needed:"
    echo "    Deallocate: az vm deallocate -g $RESOURCE_GROUP -n $AZURE_VM_NAME"
    echo "    Start again: az vm start -g $RESOURCE_GROUP -n $AZURE_VM_NAME"
    echo ""
}

################################################################################
# Generate Report
################################################################################

generate_report() {
    header "Generating Validation Report"

    cat > "$REPORT_FILE" <<EOF
# Migration Validation Report

**VM:** $AZURE_VM_NAME
**Resource Group:** $RESOURCE_GROUP
**Date:** $(date)
**Approach:** 2 — Azure Migrate

---

## Results Summary

| Category | Status |
|----------|--------|
| VM Status | $([ $FAILED -eq 0 ] && echo "✅ Pass" || echo "❌ Issues") |
| Network | See details below |
| Storage | See details below |
| SSH / OS | See details below |
| Data Integrity | See details below |
| Services | See details below |
| Security | See details below |
| Backup | See details below |

**Passed:** $PASSED | **Warnings:** $WARNINGS | **Failed:** $FAILED

---

## Access Information

\`\`\`bash
# SSH to migrated VM
ssh ${AZURE_ADMIN}@${AZURE_VM_IP}

# View VM details
az vm show -g $RESOURCE_GROUP -n $AZURE_VM_NAME --show-details

# Stop VM (save costs)
az vm deallocate -g $RESOURCE_GROUP -n $AZURE_VM_NAME

# Start VM
az vm start -g $RESOURCE_GROUP -n $AZURE_VM_NAME
\`\`\`

---

## Next Steps

$([ $FAILED -gt 0 ] && echo "### ❌ Fix Failures" && echo "Review the failed checks above and resolve before going live.")

1. **Test your application** — verify all functionality works on the Azure VM
2. **Update DNS** — point your hostname/FQDN to: ${AZURE_VM_IP}
3. **Monitor** — set up Azure Monitor alerts
4. **Enable backup** if not already done
5. **Decommission source VM** — once confident in the migration

---

*Generated by 05_validate.sh — Approach 2 Azure Migrate*
EOF

    ok "Validation report: $REPORT_FILE"
}

################################################################################
# Summary
################################################################################

show_summary() {
    header "Validation Summary"

    echo ""
    echo -e "  ${GREEN}Passed  :${NC} $PASSED"
    echo -e "  ${YELLOW}Warnings:${NC} $WARNINGS"
    echo -e "  ${RED}Failed  :${NC} $FAILED"
    echo ""

    if [[ $FAILED -eq 0 && $WARNINGS -eq 0 ]]; then
        echo -e "${GREEN}✓ Migration fully validated — VM is production-ready!${NC}"
    elif [[ $FAILED -eq 0 ]]; then
        echo -e "${YELLOW}⚠ Migration validated with warnings — review items above.${NC}"
    else
        echo -e "${RED}✗ Migration has failures — resolve before going live.${NC}"
    fi

    echo ""
    echo "  Report : $REPORT_FILE"
    echo "  Log    : $LOG_FILE"
    echo ""
    echo -e "${CYAN}Useful commands:${NC}"
    echo "  ssh ${AZURE_ADMIN}@${AZURE_VM_IP:-<ip>}"
    echo "  az vm show -g $RESOURCE_GROUP -n $AZURE_VM_NAME --show-details"
    echo ""
}

################################################################################
# Main
################################################################################

main() {
    print_banner
    preflight
    check_vm_status
    check_network
    check_storage
    check_ssh_and_os
    check_data_integrity
    check_services
    check_performance
    check_security
    check_backup
    check_cost
    generate_report
    show_summary
}

main

# Made with Bob
