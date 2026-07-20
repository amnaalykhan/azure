#!/bin/bash

################################################################################
# Azure Migrate Prerequisites Checker
# Purpose: Verify all requirements before starting migration
# Usage: ./check_migrate_prerequisites.sh [fyre-vm-hostname]
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
FYRE_VM="${1:-}"
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
# Check 1: Local Tools
################################################################################

check_local_tools() {
    print_section "Local Tools"
    
    # Azure CLI
    if command -v az &> /dev/null; then
        AZ_VERSION=$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo "unknown")
        check_pass "Azure CLI installed (version: $AZ_VERSION)"
    else
        check_fail "Azure CLI not installed"
        echo "  Install: https://docs.microsoft.com/cli/azure/install-azure-cli"
    fi
    
    # SSH
    if command -v ssh &> /dev/null; then
        SSH_VERSION=$(ssh -V 2>&1 | head -1)
        check_pass "SSH client installed ($SSH_VERSION)"
    else
        check_fail "SSH client not installed"
    fi
    
    # jq
    if command -v jq &> /dev/null; then
        JQ_VERSION=$(jq --version 2>/dev/null || echo "unknown")
        check_pass "jq installed ($JQ_VERSION)"
    else
        check_warn "jq not installed (optional but recommended)"
        echo "  Install: brew install jq (Mac) or apt install jq (Linux)"
    fi
    
    # curl
    if command -v curl &> /dev/null; then
        check_pass "curl installed"
    else
        check_fail "curl not installed"
    fi
}

################################################################################
# Check 2: Azure Authentication
################################################################################

check_azure_auth() {
    print_section "Azure Authentication"
    
    # Check if logged in
    if az account show &> /dev/null; then
        SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
        SUBSCRIPTION_ID=$(az account show --query id -o tsv)
        check_pass "Logged into Azure"
        echo "  Subscription: $SUBSCRIPTION_NAME"
        echo "  ID: $SUBSCRIPTION_ID"
    else
        check_fail "Not logged into Azure CLI"
        echo "  Run: az login"
        return
    fi
    
    # Check subscription access
    if az account list &> /dev/null; then
        SUB_COUNT=$(az account list --query "length([])" -o tsv)
        check_pass "Can list subscriptions ($SUB_COUNT available)"
    else
        check_fail "Cannot list subscriptions"
    fi
    
    # Check resource group permissions
    if az group list &> /dev/null; then
        check_pass "Can list resource groups"
    else
        check_fail "Cannot list resource groups (need Contributor role)"
    fi
}

################################################################################
# Check 3: Azure Quotas
################################################################################

check_azure_quotas() {
    print_section "Azure Quotas"
    
    LOCATION="eastus"
    
    # Check VM quota
    check_info "Checking VM quota in $LOCATION..."
    QUOTA_INFO=$(az vm list-usage --location "$LOCATION" --query "[?name.value=='cores']" -o json 2>/dev/null || echo "[]")
    
    if [ "$QUOTA_INFO" != "[]" ]; then
        CURRENT=$(echo "$QUOTA_INFO" | jq -r '.[0].currentValue' 2>/dev/null || echo "0")
        LIMIT=$(echo "$QUOTA_INFO" | jq -r '.[0].limit' 2>/dev/null || echo "0")
        AVAILABLE=$((LIMIT - CURRENT))
        
        if [ "$AVAILABLE" -ge 8 ]; then
            check_pass "VM quota available: $AVAILABLE cores (need 8+ for migration)"
        elif [ "$AVAILABLE" -ge 4 ]; then
            check_warn "VM quota limited: $AVAILABLE cores (may need smaller VM)"
        else
            check_fail "Insufficient VM quota: $AVAILABLE cores available"
            echo "  Request quota increase in Azure Portal"
        fi
    else
        check_warn "Could not check VM quota"
    fi
    
    # Check allowed locations
    check_info "Checking allowed locations..."
    ALLOWED_LOCATIONS=$(az account list-locations --query "[].name" -o tsv 2>/dev/null | wc -l)
    if [ "$ALLOWED_LOCATIONS" -gt 0 ]; then
        check_pass "Can deploy to $ALLOWED_LOCATIONS locations"
    else
        check_warn "Could not verify allowed locations"
    fi
}

################################################################################
# Check 4: Network Connectivity
################################################################################

check_network() {
    print_section "Network Connectivity"
    
    # Check Azure connectivity
    if curl -s -o /dev/null -w "%{http_code}" https://management.azure.com 2>/dev/null | grep -q "401\|200"; then
        check_pass "Can reach Azure management endpoint"
    else
        check_fail "Cannot reach Azure management endpoint"
        echo "  Check internet connection and firewall"
    fi
    
    # Check Azure Portal
    if curl -s -o /dev/null -w "%{http_code}" https://portal.azure.com 2>/dev/null | grep -q "200\|301\|302"; then
        check_pass "Can reach Azure Portal"
    else
        check_warn "Cannot reach Azure Portal (may be blocked)"
    fi
    
    # Check Fyre VM connectivity (if provided)
    if [ -n "$FYRE_VM" ]; then
        check_info "Testing Fyre VM connectivity..."
        
        # Test ping
        if ping -c 1 -W 2 "$FYRE_VM" &>/dev/null; then
            check_pass "Can ping Fyre VM: $FYRE_VM"
        else
            check_warn "Cannot ping Fyre VM (may be blocked by firewall)"
        fi
        
        # Test SSH
        if ssh -o ConnectTimeout=5 -o BatchMode=yes "$FYRE_VM" "echo 'Connected'" &>/dev/null; then
            check_pass "SSH connection successful (key-based)"
        elif ssh -o ConnectTimeout=5 "$FYRE_VM" "echo 'Connected'" &>/dev/null 2>&1; then
            check_warn "SSH requires password (key-based auth recommended)"
        else
            check_fail "Cannot connect to Fyre VM via SSH"
            echo "  Verify: ssh $FYRE_VM"
        fi
    fi
}

################################################################################
# Check 5: Fyre VM Requirements (if hostname provided)
################################################################################

check_fyre_vm() {
    if [ -z "$FYRE_VM" ]; then
        print_section "Fyre VM Requirements"
        check_info "Skipped (no Fyre VM hostname provided)"
        echo "  Run with: $0 <fyre-vm-hostname>"
        return
    fi
    
    print_section "Fyre VM Requirements"
    
    check_info "Checking Fyre VM: $FYRE_VM"
    
    # Check OS
    if OS_INFO=$(ssh "$FYRE_VM" "cat /etc/os-release" 2>/dev/null); then
        OS_NAME=$(echo "$OS_INFO" | grep "^NAME=" | cut -d'"' -f2)
        OS_VERSION=$(echo "$OS_INFO" | grep "^VERSION=" | cut -d'"' -f2)
        check_pass "OS detected: $OS_NAME $OS_VERSION"
        
        # Check if supported
        if echo "$OS_NAME" | grep -qi "red hat\|rhel\|centos\|ubuntu\|debian"; then
            check_pass "OS is supported by Azure Migrate"
        else
            check_warn "OS may not be fully supported: $OS_NAME"
        fi
    else
        check_fail "Cannot detect OS on Fyre VM"
    fi
    
    # Check disk space
    if DISK_SPACE=$(ssh "$FYRE_VM" "df -BG / | tail -1 | awk '{print \$4}' | sed 's/G//'" 2>/dev/null); then
        if [ "$DISK_SPACE" -gt 10 ]; then
            check_pass "Sufficient disk space: ${DISK_SPACE}GB available"
        else
            check_warn "Low disk space: ${DISK_SPACE}GB available"
        fi
    else
        check_warn "Cannot check disk space"
    fi
    
    # Check memory
    if MEMORY=$(ssh "$FYRE_VM" "free -g | grep Mem | awk '{print \$2}'" 2>/dev/null); then
        check_pass "Memory: ${MEMORY}GB"
    else
        check_warn "Cannot check memory"
    fi
    
    # Check if root/sudo access
    if ssh "$FYRE_VM" "sudo -n true" &>/dev/null; then
        check_pass "Has sudo access (required for migration)"
    else
        check_warn "May not have passwordless sudo (needed for automation)"
    fi
    
    # Check required ports
    check_info "Checking required ports..."
    if ssh "$FYRE_VM" "command -v ss &>/dev/null || command -v netstat &>/dev/null" &>/dev/null; then
        check_pass "Network tools available"
    else
        check_warn "Network diagnostic tools not found"
    fi
}

################################################################################
# Check 6: Azure Migrate Specific
################################################################################

check_azure_migrate() {
    print_section "Azure Migrate Requirements"
    
    # Check if Azure Migrate is available in subscription
    if az provider show --namespace Microsoft.Migrate &>/dev/null; then
        check_pass "Azure Migrate provider available"
    else
        check_warn "Azure Migrate provider not registered"
        echo "  May need to register: az provider register --namespace Microsoft.Migrate"
    fi
    
    # Check if can create resources
    if az group list &>/dev/null; then
        check_pass "Can create resource groups"
    else
        check_fail "Cannot create resource groups"
    fi
    
    # Check storage account availability
    check_info "Checking storage account naming..."
    RANDOM_NAME="migrate$(date +%s | tail -c 6)"
    if az storage account check-name --name "$RANDOM_NAME" --query "nameAvailable" -o tsv 2>/dev/null | grep -q "true"; then
        check_pass "Storage account names available"
    else
        check_warn "May have storage account naming conflicts"
    fi
}

################################################################################
# Check 7: Estimated Costs
################################################################################

check_costs() {
    print_section "Cost Estimates"
    
    check_info "Estimated monthly costs for Azure Migrate:"
    echo ""
    echo "  Migration Phase (temporary):"
    echo "    - Appliance VM (Standard_D4s_v3): ~\$140/month"
    echo "    - Replication storage: ~\$50/month"
    echo "    - Network egress: ~\$10/month"
    echo "    Total: ~\$200/month (delete after migration)"
    echo ""
    echo "  Production VM (ongoing):"
    echo "    - VM (Standard_D4s_v3): ~\$140/month"
    echo "    - Storage (500GB Premium SSD): ~\$100/month"
    echo "    - Backup: ~\$10/month"
    echo "    Total: ~\$250/month"
    echo ""
    check_info "Total migration cost: ~\$200 (one-time) + \$250/month (ongoing)"
}

################################################################################
# Summary
################################################################################

show_summary() {
    print_header "Prerequisites Check Summary"
    
    echo "Results:"
    echo -e "  ${GREEN}Passed:${NC} $PASSED"
    echo -e "  ${YELLOW}Warnings:${NC} $WARNINGS"
    echo -e "  ${RED}Failed:${NC} $FAILED"
    echo ""
    
    if [ $FAILED -eq 0 ]; then
        if [ $WARNINGS -eq 0 ]; then
            echo -e "${GREEN}✓ All prerequisites met! Ready to migrate.${NC}"
            echo ""
            echo "Next steps:"
            echo "  1. Run: ./azure_migrate_discover.sh $FYRE_VM"
            echo "  2. Or: ./azure_migrate_complete.sh $FYRE_VM"
        else
            echo -e "${YELLOW}⚠ Prerequisites mostly met with some warnings.${NC}"
            echo ""
            echo "You can proceed, but review warnings above."
            echo ""
            echo "Next steps:"
            echo "  1. Address warnings if possible"
            echo "  2. Run: ./azure_migrate_discover.sh $FYRE_VM"
        fi
    else
        echo -e "${RED}✗ Some prerequisites failed. Please fix issues above.${NC}"
        echo ""
        echo "Common fixes:"
        echo "  - Install Azure CLI: https://docs.microsoft.com/cli/azure/install-azure-cli"
        echo "  - Login to Azure: az login"
        echo "  - Setup SSH keys: ssh-keygen && ssh-copy-id $FYRE_VM"
        echo "  - Request quota increase in Azure Portal"
    fi
    
    echo ""
}

################################################################################
# Main Execution
################################################################################

main() {
    clear
    print_header "Azure Migrate Prerequisites Checker"
    
    if [ -n "$FYRE_VM" ]; then
        echo "Target Fyre VM: $FYRE_VM"
    else
        echo "No Fyre VM specified (will skip VM-specific checks)"
        echo "Usage: $0 <fyre-vm-hostname>"
    fi
    
    check_local_tools
    check_azure_auth
    check_azure_quotas
    check_network
    check_fyre_vm
    check_azure_migrate
    check_costs
    show_summary
}

# Run main function
main

# Made with Bob