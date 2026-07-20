#!/bin/bash

################################################################################
# Azure Migrate Migration Validator
# Purpose: Validate migrated VM and verify everything works
# Usage: ./validate_migration.sh <azure-vm-name> [resource-group]
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
VM_NAME="${1:-}"
RESOURCE_GROUP="${2:-rg-azure-migrate}"
PASSED=0
FAILED=0
WARNINGS=0

################################################################################
# Helper Functions
################################################################################

print_header() {
    echo ""
    echo -e "${CYAN}================================================================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}================================================================================${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${BLUE}────────────────────────────────────────────────────────────────────────────${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}────────────────────────────────────────────────────────────────────────────${NC}"
}

check_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((PASSED++))
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
    ((FAILED++))
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
    ((WARNINGS++))
}

check_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

################################################################################
# Check 1: VM Exists and Running
################################################################################

check_vm_status() {
    print_section "VM Status"
    
    # Check if VM exists
    if az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" &>/dev/null; then
        check_pass "VM exists: $VM_NAME"
    else
        check_fail "VM not found: $VM_NAME in $RESOURCE_GROUP"
        return 1
    fi
    
    # Get VM details
    VM_INFO=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --show-details -o json)
    
    # Check power state
    POWER_STATE=$(echo "$VM_INFO" | jq -r '.powerState' 2>/dev/null || echo "unknown")
    if [ "$POWER_STATE" = "VM running" ]; then
        check_pass "VM is running"
    else
        check_fail "VM is not running: $POWER_STATE"
    fi
    
    # Get VM size
    VM_SIZE=$(echo "$VM_INFO" | jq -r '.hardwareProfile.vmSize' 2>/dev/null || echo "unknown")
    check_info "VM Size: $VM_SIZE"
    
    # Get location
    LOCATION=$(echo "$VM_INFO" | jq -r '.location' 2>/dev/null || echo "unknown")
    check_info "Location: $LOCATION"
    
    # Get OS
    OS_TYPE=$(echo "$VM_INFO" | jq -r '.storageProfile.osDisk.osType' 2>/dev/null || echo "unknown")
    check_info "OS Type: $OS_TYPE"
}

################################################################################
# Check 2: Network Configuration
################################################################################

check_network() {
    print_section "Network Configuration"
    
    VM_INFO=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --show-details -o json)
    
    # Check public IP
    PUBLIC_IP=$(echo "$VM_INFO" | jq -r '.publicIps' 2>/dev/null || echo "")
    if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "null" ]; then
        check_pass "Public IP assigned: $PUBLIC_IP"
        echo "  SSH: ssh azureuser@$PUBLIC_IP"
    else
        check_warn "No public IP assigned (may be internal only)"
    fi
    
    # Check private IP
    PRIVATE_IP=$(echo "$VM_INFO" | jq -r '.privateIps' 2>/dev/null || echo "")
    if [ -n "$PRIVATE_IP" ] && [ "$PRIVATE_IP" != "null" ]; then
        check_pass "Private IP assigned: $PRIVATE_IP"
    else
        check_fail "No private IP assigned"
    fi
    
    # Check NSG
    NSG=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --query "networkProfile.networkInterfaces[0].id" -o tsv 2>/dev/null)
    if [ -n "$NSG" ]; then
        check_pass "Network interface configured"
    else
        check_warn "Could not verify network interface"
    fi
    
    # Check if SSH port is open
    if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "null" ]; then
        check_info "Testing SSH connectivity..."
        if timeout 5 bash -c "echo > /dev/tcp/$PUBLIC_IP/22" 2>/dev/null; then
            check_pass "SSH port (22) is accessible"
        else
            check_warn "SSH port (22) not accessible (may need NSG rule)"
        fi
    fi
}

################################################################################
# Check 3: Storage Configuration
################################################################################

check_storage() {
    print_section "Storage Configuration"
    
    VM_INFO=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" -o json)
    
    # Check OS disk
    OS_DISK=$(echo "$VM_INFO" | jq -r '.storageProfile.osDisk.name' 2>/dev/null || echo "unknown")
    OS_DISK_SIZE=$(echo "$VM_INFO" | jq -r '.storageProfile.osDisk.diskSizeGb' 2>/dev/null || echo "unknown")
    OS_DISK_TYPE=$(echo "$VM_INFO" | jq -r '.storageProfile.osDisk.managedDisk.storageAccountType' 2>/dev/null || echo "unknown")
    
    if [ "$OS_DISK" != "unknown" ]; then
        check_pass "OS Disk: $OS_DISK (${OS_DISK_SIZE}GB, $OS_DISK_TYPE)"
    else
        check_fail "Could not verify OS disk"
    fi
    
    # Check data disks
    DATA_DISK_COUNT=$(echo "$VM_INFO" | jq -r '.storageProfile.dataDisks | length' 2>/dev/null || echo "0")
    if [ "$DATA_DISK_COUNT" -gt 0 ]; then
        check_pass "Data disks attached: $DATA_DISK_COUNT"
        echo "$VM_INFO" | jq -r '.storageProfile.dataDisks[] | "  - \(.name) (\(.diskSizeGb)GB, \(.managedDisk.storageAccountType))"' 2>/dev/null
    else
        check_info "No data disks attached"
    fi
}

################################################################################
# Check 4: SSH Connectivity
################################################################################

check_ssh() {
    print_section "SSH Connectivity"
    
    VM_INFO=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --show-details -o json)
    PUBLIC_IP=$(echo "$VM_INFO" | jq -r '.publicIps' 2>/dev/null || echo "")
    
    if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "null" ]; then
        check_warn "No public IP - skipping SSH test"
        return
    fi
    
    check_info "Testing SSH connection to $PUBLIC_IP..."
    
    # Test SSH with timeout
    if timeout 10 ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "azureuser@$PUBLIC_IP" "echo 'Connected'" &>/dev/null; then
        check_pass "SSH connection successful (key-based)"
        
        # Get hostname
        HOSTNAME=$(timeout 5 ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "azureuser@$PUBLIC_IP" "hostname" 2>/dev/null || echo "unknown")
        check_info "Remote hostname: $HOSTNAME"
        
        # Check uptime
        UPTIME=$(timeout 5 ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "azureuser@$PUBLIC_IP" "uptime -p" 2>/dev/null || echo "unknown")
        check_info "Uptime: $UPTIME"
        
    else
        check_warn "Cannot connect via SSH (may need password or key setup)"
        echo "  Try: ssh azureuser@$PUBLIC_IP"
    fi
}

################################################################################
# Check 5: VM Performance
################################################################################

check_performance() {
    print_section "VM Performance Metrics"
    
    VM_INFO=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --show-details -o json)
    PUBLIC_IP=$(echo "$VM_INFO" | jq -r '.publicIps' 2>/dev/null || echo "")
    
    if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "null" ]; then
        check_warn "No public IP - skipping performance checks"
        return
    fi
    
    if ! timeout 5 ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "azureuser@$PUBLIC_IP" "echo 'test'" &>/dev/null; then
        check_warn "Cannot SSH - skipping performance checks"
        return
    fi
    
    check_info "Collecting performance metrics..."
    
    # CPU info
    CPU_COUNT=$(timeout 5 ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "azureuser@$PUBLIC_IP" "nproc" 2>/dev/null || echo "unknown")
    check_info "CPU Cores: $CPU_COUNT"
    
    # Memory info
    MEMORY_TOTAL=$(timeout 5 ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "azureuser@$PUBLIC_IP" "free -h | grep Mem | awk '{print \$2}'" 2>/dev/null || echo "unknown")
    MEMORY_USED=$(timeout 5 ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "azureuser@$PUBLIC_IP" "free -h | grep Mem | awk '{print \$3}'" 2>/dev/null || echo "unknown")
    check_info "Memory: $MEMORY_USED / $MEMORY_TOTAL used"
    
    # Disk usage
    DISK_USAGE=$(timeout 5 ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "azureuser@$PUBLIC_IP" "df -h / | tail -1 | awk '{print \$5}'" 2>/dev/null || echo "unknown")
    check_info "Root disk usage: $DISK_USAGE"
    
    # Load average
    LOAD_AVG=$(timeout 5 ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "azureuser@$PUBLIC_IP" "uptime | awk -F'load average:' '{print \$2}'" 2>/dev/null || echo "unknown")
    check_info "Load average:$LOAD_AVG"
}

################################################################################
# Check 6: Backup Configuration
################################################################################

check_backup() {
    print_section "Backup Configuration"
    
    # Check if backup is enabled
    BACKUP_INFO=$(az backup protection check-vm \
        --resource-group "$RESOURCE_GROUP" \
        --vm-name "$VM_NAME" \
        -o json 2>/dev/null || echo "{}")
    
    if echo "$BACKUP_INFO" | jq -e '.properties.protectionStatus' &>/dev/null; then
        BACKUP_STATUS=$(echo "$BACKUP_INFO" | jq -r '.properties.protectionStatus' 2>/dev/null || echo "unknown")
        if [ "$BACKUP_STATUS" = "Protected" ]; then
            check_pass "Azure Backup is enabled"
        else
            check_warn "Azure Backup status: $BACKUP_STATUS"
        fi
    else
        check_warn "Azure Backup not configured (recommended for production)"
        echo "  Enable in Azure Portal or with: az backup protection enable-for-vm"
    fi
}

################################################################################
# Check 7: Cost Analysis
################################################################################

check_costs() {
    print_section "Cost Information"
    
    VM_INFO=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" -o json)
    VM_SIZE=$(echo "$VM_INFO" | jq -r '.hardwareProfile.vmSize' 2>/dev/null || echo "unknown")
    
    check_info "Estimated monthly costs for $VM_SIZE:"
    
    case "$VM_SIZE" in
        *D2s*)
            echo "  VM: ~\$70/month"
            ;;
        *D4s*)
            echo "  VM: ~\$140/month"
            ;;
        *D8s*)
            echo "  VM: ~\$280/month"
            ;;
        *)
            echo "  VM: Check Azure pricing calculator"
            ;;
    esac
    
    echo "  Storage: ~\$50-100/month (depends on disk size/type)"
    echo "  Backup: ~\$10/month"
    echo "  Network: ~\$5/month"
    echo ""
    check_info "To save costs when not in use:"
    echo "  Stop VM: az vm deallocate -g $RESOURCE_GROUP -n $VM_NAME"
    echo "  Start VM: az vm start -g $RESOURCE_GROUP -n $VM_NAME"
}

################################################################################
# Check 8: Security
################################################################################

check_security() {
    print_section "Security Configuration"
    
    VM_INFO=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" -o json)
    
    # Check if password auth is disabled
    DISABLE_PASSWORD=$(echo "$VM_INFO" | jq -r '.osProfile.linuxConfiguration.disablePasswordAuthentication' 2>/dev/null || echo "unknown")
    if [ "$DISABLE_PASSWORD" = "true" ]; then
        check_pass "Password authentication disabled (SSH keys only)"
    else
        check_warn "Password authentication may be enabled"
    fi
    
    # Check if boot diagnostics enabled
    BOOT_DIAG=$(echo "$VM_INFO" | jq -r '.diagnosticsProfile.bootDiagnostics.enabled' 2>/dev/null || echo "false")
    if [ "$BOOT_DIAG" = "true" ]; then
        check_pass "Boot diagnostics enabled"
    else
        check_warn "Boot diagnostics not enabled"
    fi
    
    # Check NSG rules
    check_info "Checking NSG rules..."
    NIC_ID=$(echo "$VM_INFO" | jq -r '.networkProfile.networkInterfaces[0].id' 2>/dev/null)
    if [ -n "$NIC_ID" ]; then
        NSG_ID=$(az network nic show --ids "$NIC_ID" --query "networkSecurityGroup.id" -o tsv 2>/dev/null || echo "")
        if [ -n "$NSG_ID" ]; then
            check_pass "Network Security Group attached"
        else
            check_warn "No NSG attached to network interface"
        fi
    fi
}

################################################################################
# Summary
################################################################################

show_summary() {
    print_header "Validation Summary"
    
    echo "Results:"
    echo -e "  ${GREEN}Passed:${NC} $PASSED"
    echo -e "  ${YELLOW}Warnings:${NC} $WARNINGS"
    echo -e "  ${RED}Failed:${NC} $FAILED"
    echo ""
    
    if [ $FAILED -eq 0 ]; then
        if [ $WARNINGS -eq 0 ]; then
            echo -e "${GREEN}✓ Migration validated successfully!${NC}"
            echo ""
            echo "Your VM is ready for production use."
        else
            echo -e "${YELLOW}⚠ Migration mostly successful with some warnings.${NC}"
            echo ""
            echo "Review warnings above and address if needed."
        fi
    else
        echo -e "${RED}✗ Some validation checks failed.${NC}"
        echo ""
        echo "Please review and fix the issues above."
    fi
    
    echo ""
    echo "Next steps:"
    echo "  1. Test your application on the Azure VM"
    echo "  2. Update DNS to point to Azure IP"
    echo "  3. Monitor performance in Azure Portal"
    echo "  4. Configure backup if not already enabled"
    echo "  5. Delete source Fyre VM when confident"
    echo ""
    
    # Show useful commands
    print_section "Useful Commands"
    
    VM_INFO=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --show-details -o json)
    PUBLIC_IP=$(echo "$VM_INFO" | jq -r '.publicIps' 2>/dev/null || echo "")
    
    if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "null" ]; then
        echo "SSH to VM:"
        echo "  ${CYAN}ssh azureuser@$PUBLIC_IP${NC}"
        echo ""
    fi
    
    echo "Stop VM (save costs):"
    echo "  ${CYAN}az vm deallocate -g $RESOURCE_GROUP -n $VM_NAME${NC}"
    echo ""
    echo "Start VM:"
    echo "  ${CYAN}az vm start -g $RESOURCE_GROUP -n $VM_NAME${NC}"
    echo ""
    echo "View VM details:"
    echo "  ${CYAN}az vm show -g $RESOURCE_GROUP -n $VM_NAME --show-details${NC}"
    echo ""
    echo "Delete VM (when done):"
    echo "  ${CYAN}az vm delete -g $RESOURCE_GROUP -n $VM_NAME --yes${NC}"
    echo ""
}

################################################################################
# Main Execution
################################################################################

main() {
    clear
    print_header "Azure Migrate - Migration Validator"
    
    # Check if VM name provided
    if [ -z "$VM_NAME" ]; then
        echo -e "${RED}Error: No VM name provided${NC}"
        echo ""
        echo "Usage: $0 <azure-vm-name> [resource-group]"
        echo "Example: $0 fyre-vm-1 rg-azure-migrate"
        exit 1
    fi
    
    echo "Validating VM: $VM_NAME"
    echo "Resource Group: $RESOURCE_GROUP"
    
    # Check Azure CLI
    if ! command -v az &> /dev/null; then
        echo -e "${RED}Error: Azure CLI not installed${NC}"
        exit 1
    fi
    
    # Check Azure login
    if ! az account show &> /dev/null; then
        echo -e "${RED}Error: Not logged into Azure CLI${NC}"
        echo "Run: az login"
        exit 1
    fi
    
    # Run all checks
    check_vm_status
    check_network
    check_storage
    check_ssh
    check_performance
    check_backup
    check_costs
    check_security
    show_summary
}

# Run main function
main

# Made with Bob