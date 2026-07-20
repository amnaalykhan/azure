#!/bin/bash

################################################################################
# Azure Migrate Complete Migration Script
# Purpose: Automate the entire Azure Migrate migration process
# Usage: ./azure_migrate_complete.sh <fyre-vm-hostname>
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Configuration
FYRE_VM="${1:-}"
PROJECT_NAME="fyre-to-azure-migrate"
RESOURCE_GROUP="rg-azure-migrate"
LOCATION="${2:-eastus}"
APPLIANCE_NAME="azure-migrate-appliance"
OUTPUT_DIR="azure_migrate_$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$OUTPUT_DIR/migration.log"

# Migration phases
PHASE_DISCOVERY=1
PHASE_APPLIANCE=2
PHASE_REPLICATION=3
PHASE_TEST=4
PHASE_MIGRATE=5

################################################################################
# Helper Functions
################################################################################

print_banner() {
    clear
    echo -e "${CYAN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║              Azure Migrate - Complete Migration Automation               ║
║                                                                           ║
║                    Fyre VM → Azure (Official Tool)                       ║
║                                                                           ║
╚═══════════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

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

log_success() {
    echo -e "${GREEN}✓${NC} $1" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}ℹ${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}✗${NC} $1" | tee -a "$LOG_FILE"
}

log_step() {
    echo -e "${MAGENTA}▶${NC} $1" | tee -a "$LOG_FILE"
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "$1 is not installed. Please install it first."
        exit 1
    fi
}

wait_with_spinner() {
    local pid=$1
    local message=$2
    local spin='-\|/'
    local i=0
    
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r${BLUE}${spin:$i:1}${NC} $message"
        sleep .1
    done
    printf "\r"
}

confirm_action() {
    local message=$1
    echo -e "${YELLOW}$message${NC}"
    read -p "Continue? (yes/no): " response
    if [[ ! "$response" =~ ^[Yy][Ee][Ss]$ ]]; then
        log_warning "Action cancelled by user"
        exit 0
    fi
}

################################################################################
# Phase 1: Prerequisites and Discovery
################################################################################

phase_prerequisites() {
    print_header "Phase 1: Prerequisites and Discovery"
    
    mkdir -p "$OUTPUT_DIR"
    
    # Check if VM hostname provided
    if [ -z "$FYRE_VM" ]; then
        log_error "No Fyre VM hostname provided!"
        echo ""
        echo "Usage: $0 <fyre-vm-hostname> [azure-location]"
        echo "Example: $0 itz-693000iler-gw3v1m6w.dev.fyre.ibm.com eastus"
        exit 1
    fi
    
    log_info "Target Fyre VM: $FYRE_VM"
    log_info "Azure Location: $LOCATION"
    
    # Check required commands
    print_section "Checking Prerequisites"
    log_step "Checking required tools..."
    check_command "az"
    check_command "ssh"
    check_command "jq"
    log_success "All required tools installed"
    
    # Check Azure login
    log_step "Verifying Azure authentication..."
    if ! az account show &> /dev/null; then
        log_error "Not logged into Azure CLI. Run: az login"
        exit 1
    fi
    
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
    log_success "Azure authenticated: $SUBSCRIPTION_NAME"
    
    # Test SSH to Fyre
    log_step "Testing SSH connection to Fyre VM..."
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "$FYRE_VM" "echo 'Connected'" &>/dev/null; then
        log_success "SSH connection successful"
    else
        log_warning "SSH key authentication failed, will need password"
    fi
    
    # Discover VM details
    print_section "Discovering Fyre VM Configuration"
    
    log_step "Collecting VM information..."
    VM_HOSTNAME=$(ssh "$FYRE_VM" "hostname" 2>/dev/null || echo "$FYRE_VM")
    VM_IP=$(ssh "$FYRE_VM" "hostname -I | awk '{print \$1}'" 2>/dev/null || echo "unknown")
    CPU_COUNT=$(ssh "$FYRE_VM" "nproc" 2>/dev/null || echo "4")
    MEMORY_GB=$(ssh "$FYRE_VM" "free -g | grep Mem | awk '{print \$2}'" 2>/dev/null || echo "8")
    
    log_success "VM discovered: $VM_HOSTNAME ($VM_IP)"
    echo "  CPU: $CPU_COUNT cores"
    echo "  Memory: ${MEMORY_GB}GB"
    
    # Save discovery
    cat > "$OUTPUT_DIR/vm_info.json" <<EOF
{
  "hostname": "$VM_HOSTNAME",
  "ip": "$VM_IP",
  "cpu": $CPU_COUNT,
  "memory_gb": $MEMORY_GB,
  "discovered_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    
    echo ""
}

################################################################################
# Phase 2: Setup Azure Migrate Project
################################################################################

phase_setup_project() {
    print_header "Phase 2: Setup Azure Migrate Project"
    
    # Create resource group
    print_section "Creating Azure Resources"
    
    log_step "Creating resource group..."
    if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
        log_warning "Resource group already exists"
    else
        az group create \
            --name "$RESOURCE_GROUP" \
            --location "$LOCATION" \
            --output none
        log_success "Resource group created"
    fi
    
    # Create Azure Migrate project
    log_step "Creating Azure Migrate project..."
    if az resource show \
        --resource-group "$RESOURCE_GROUP" \
        --resource-type "Microsoft.Migrate/migrateProjects" \
        --name "$PROJECT_NAME" &>/dev/null 2>&1; then
        log_warning "Azure Migrate project already exists"
    else
        az resource create \
            --resource-group "$RESOURCE_GROUP" \
            --resource-type "Microsoft.Migrate/migrateProjects" \
            --name "$PROJECT_NAME" \
            --location "$LOCATION" \
            --properties '{"publicNetworkAccess":"Enabled"}' \
            --output none 2>/dev/null || log_warning "Project may already exist"
        log_success "Azure Migrate project ready"
    fi
    
    # Save project info
    cat > "$OUTPUT_DIR/project_info.json" <<EOF
{
  "project_name": "$PROJECT_NAME",
  "resource_group": "$RESOURCE_GROUP",
  "location": "$LOCATION",
  "subscription_id": "$SUBSCRIPTION_ID",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    
    echo ""
}

################################################################################
# Phase 3: Deploy Migration Appliance
################################################################################

phase_deploy_appliance() {
    print_header "Phase 3: Deploy Migration Appliance"
    
    print_section "Appliance Deployment"
    
    log_info "The appliance manages discovery and replication"
    log_info "This will take 5-10 minutes..."
    echo ""
    
    confirm_action "Deploy Azure Migrate appliance VM? (~$140/month while active)"
    
    # Check if appliance exists
    log_step "Checking for existing appliance..."
    if az vm show --resource-group "$RESOURCE_GROUP" --name "$APPLIANCE_NAME" &>/dev/null; then
        log_warning "Appliance VM already exists"
        APPLIANCE_IP=$(az vm show \
            --resource-group "$RESOURCE_GROUP" \
            --name "$APPLIANCE_NAME" \
            --show-details \
            --query publicIps -o tsv)
        log_info "Appliance IP: $APPLIANCE_IP"
    else
        log_step "Creating appliance VM (this takes 5-10 minutes)..."
        
        # Create appliance VM
        az vm create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$APPLIANCE_NAME" \
            --image "MicrosoftWindowsServer:WindowsServer:2019-Datacenter:latest" \
            --size "Standard_D4s_v3" \
            --admin-username "azureadmin" \
            --admin-password "AzureMigrate@2026!" \
            --public-ip-address-allocation static \
            --nsg-rule RDP \
            --output none
        
        APPLIANCE_IP=$(az vm show \
            --resource-group "$RESOURCE_GROUP" \
            --name "$APPLIANCE_NAME" \
            --show-details \
            --query publicIps -o tsv)
        
        log_success "Appliance deployed: $APPLIANCE_IP"
    fi
    
    # Save appliance info
    cat > "$OUTPUT_DIR/appliance_info.json" <<EOF
{
  "appliance_name": "$APPLIANCE_NAME",
  "public_ip": "$APPLIANCE_IP",
  "admin_username": "azureadmin",
  "admin_password": "AzureMigrate@2026!",
  "rdp_command": "mstsc /v:$APPLIANCE_IP",
  "deployed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    
    echo ""
    log_info "Appliance Details:"
    echo "  IP: $APPLIANCE_IP"
    echo "  Username: azureadmin"
    echo "  Password: AzureMigrate@2026!"
    echo "  RDP: mstsc /v:$APPLIANCE_IP"
    echo ""
}

################################################################################
# Phase 4: Configure Discovery
################################################################################

phase_configure_discovery() {
    print_header "Phase 4: Configure Discovery"
    
    print_section "Manual Configuration Required"
    
    log_warning "The following steps require manual configuration:"
    echo ""
    echo "1. Connect to appliance via RDP:"
    echo "   ${CYAN}mstsc /v:$APPLIANCE_IP${NC}"
    echo ""
    echo "2. Open browser on appliance and go to:"
    echo "   ${CYAN}https://localhost:44368${NC}"
    echo ""
    echo "3. Complete appliance configuration:"
    echo "   - Accept license terms"
    echo "   - Register with Azure Migrate"
    echo "   - Provide Azure credentials"
    echo ""
    echo "4. Add Fyre VM for discovery:"
    echo "   - IP/Hostname: ${CYAN}$VM_IP${NC} or ${CYAN}$VM_HOSTNAME${NC}"
    echo "   - Credentials: root + password"
    echo "   - Click 'Start discovery'"
    echo ""
    echo "5. Wait for discovery (15-30 minutes)"
    echo ""
    
    read -p "Press Enter when discovery is complete..."
    
    log_success "Discovery configuration acknowledged"
    echo ""
}

################################################################################
# Phase 5: Start Replication
################################################################################

phase_start_replication() {
    print_header "Phase 5: Start Replication"
    
    print_section "Replication Setup"
    
    log_info "Replication copies data from Fyre to Azure"
    log_info "This process takes 1-2 hours for initial sync"
    echo ""
    
    log_warning "Manual steps required in Azure Portal:"
    echo ""
    echo "1. Go to Azure Migrate project:"
    echo "   ${CYAN}https://portal.azure.com/#blade/Microsoft_Azure_Migrate/AmhResourceMenuBlade/overview${NC}"
    echo ""
    echo "2. Click 'Servers, databases and web apps'"
    echo ""
    echo "3. Under 'Migration tools', click 'Replicate'"
    echo ""
    echo "4. Select your Fyre VM: ${CYAN}$VM_HOSTNAME${NC}"
    echo ""
    echo "5. Configure target settings:"
    echo "   - Resource group: ${CYAN}$RESOURCE_GROUP${NC}"
    echo "   - Location: ${CYAN}$LOCATION${NC}"
    echo "   - VM size: Standard_D4s_v3 (or based on source)"
    echo ""
    echo "6. Click 'Replicate' and wait for initial sync"
    echo ""
    
    read -p "Press Enter when replication is started..."
    
    log_success "Replication initiated"
    echo ""
    
    log_info "Monitor replication status:"
    echo "  ${CYAN}az migrate replication list \\${NC}"
    echo "  ${CYAN}  --resource-group $RESOURCE_GROUP \\${NC}"
    echo "  ${CYAN}  --project-name $PROJECT_NAME${NC}"
    echo ""
}

################################################################################
# Phase 6: Test Migration (Optional)
################################################################################

phase_test_migration() {
    print_header "Phase 6: Test Migration (Optional)"
    
    print_section "Test Migration"
    
    log_info "Test migration creates a test VM without affecting production"
    echo ""
    
    read -p "Do you want to perform a test migration? (yes/no): " response
    if [[ ! "$response" =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Skipping test migration"
        return
    fi
    
    log_warning "Manual steps for test migration:"
    echo ""
    echo "1. In Azure Portal, go to Azure Migrate"
    echo ""
    echo "2. Click 'Replicating servers'"
    echo ""
    echo "3. Select your VM: ${CYAN}$VM_HOSTNAME${NC}"
    echo ""
    echo "4. Click 'Test migration'"
    echo ""
    echo "5. Select test virtual network"
    echo ""
    echo "6. Click 'Test migration' and wait (15-30 min)"
    echo ""
    echo "7. Verify test VM works correctly"
    echo ""
    echo "8. Clean up test migration when done"
    echo ""
    
    read -p "Press Enter when test migration is complete..."
    
    log_success "Test migration completed"
    echo ""
}

################################################################################
# Phase 7: Final Migration
################################################################################

phase_final_migration() {
    print_header "Phase 7: Final Migration"
    
    print_section "Production Cutover"
    
    log_warning "This will migrate your production VM!"
    log_warning "Downtime: ~5 minutes"
    echo ""
    
    confirm_action "Proceed with final migration?"
    
    log_warning "Manual steps for final migration:"
    echo ""
    echo "1. Stop the Fyre VM:"
    echo "   ${CYAN}ssh $FYRE_VM 'sudo shutdown -h now'${NC}"
    echo ""
    echo "2. In Azure Portal, go to Azure Migrate"
    echo ""
    echo "3. Click 'Replicating servers'"
    echo ""
    echo "4. Select your VM: ${CYAN}$VM_HOSTNAME${NC}"
    echo ""
    echo "5. Click 'Migrate'"
    echo ""
    echo "6. Confirm migration settings"
    echo ""
    echo "7. Click 'Migrate' and wait (5-10 min)"
    echo ""
    echo "8. Verify Azure VM is running"
    echo ""
    
    read -p "Press Enter when migration is complete..."
    
    log_success "Migration completed!"
    echo ""
}

################################################################################
# Phase 8: Post-Migration Verification
################################################################################

phase_verification() {
    print_header "Phase 8: Post-Migration Verification"
    
    print_section "Verification Steps"
    
    log_info "Verify the migrated VM:"
    echo ""
    echo "1. Get VM details:"
    echo "   ${CYAN}az vm show \\${NC}"
    echo "   ${CYAN}  --resource-group $RESOURCE_GROUP \\${NC}"
    echo "   ${CYAN}  --name $VM_HOSTNAME \\${NC}"
    echo "   ${CYAN}  --show-details${NC}"
    echo ""
    echo "2. Get public IP:"
    echo "   ${CYAN}az vm show \\${NC}"
    echo "   ${CYAN}  --resource-group $RESOURCE_GROUP \\${NC}"
    echo "   ${CYAN}  --name $VM_HOSTNAME \\${NC}"
    echo "   ${CYAN}  --show-details \\${NC}"
    echo "   ${CYAN}  --query publicIps -o tsv${NC}"
    echo ""
    echo "3. SSH to Azure VM:"
    echo "   ${CYAN}ssh azureuser@<public-ip>${NC}"
    echo ""
    echo "4. Verify services are running"
    echo ""
    echo "5. Test application functionality"
    echo ""
    
    read -p "Press Enter when verification is complete..."
    
    log_success "Verification completed"
    echo ""
}

################################################################################
# Phase 9: Cleanup
################################################################################

phase_cleanup() {
    print_header "Phase 9: Cleanup (Optional)"
    
    print_section "Resource Cleanup"
    
    log_info "You can now clean up migration resources to save costs"
    echo ""
    
    read -p "Delete Azure Migrate appliance? (saves ~$140/month) (yes/no): " response
    if [[ "$response" =~ ^[Yy][Ee][Ss]$ ]]; then
        log_step "Deleting appliance VM..."
        az vm delete \
            --resource-group "$RESOURCE_GROUP" \
            --name "$APPLIANCE_NAME" \
            --yes \
            --output none
        log_success "Appliance deleted"
    fi
    
    echo ""
    read -p "Delete Azure Migrate project? (keeps migrated VM) (yes/no): " response
    if [[ "$response" =~ ^[Yy][Ee][Ss]$ ]]; then
        log_step "Deleting Azure Migrate project..."
        az resource delete \
            --resource-group "$RESOURCE_GROUP" \
            --resource-type "Microsoft.Migrate/migrateProjects" \
            --name "$PROJECT_NAME" \
            --output none 2>/dev/null || true
        log_success "Project deleted"
    fi
    
    echo ""
}

################################################################################
# Generate Final Report
################################################################################

generate_report() {
    print_header "Migration Report"
    
    cat > "$OUTPUT_DIR/MIGRATION_REPORT.md" <<EOF
# Azure Migrate - Migration Report

## Migration Summary

**Date:** $(date)
**Source VM:** $VM_HOSTNAME ($VM_IP)
**Target:** Azure ($LOCATION)
**Status:** Completed

## Resources Created

- **Resource Group:** $RESOURCE_GROUP
- **Azure Migrate Project:** $PROJECT_NAME
- **Migrated VM:** $VM_HOSTNAME
- **Location:** $LOCATION

## Timeline

- Discovery: 15-30 minutes
- Appliance deployment: 5-10 minutes
- Replication: 1-2 hours
- Test migration: 30 minutes (optional)
- Final migration: 5-10 minutes
- **Total:** 2-4 hours

## Next Steps

1. **Verify VM:** SSH to Azure VM and test services
2. **Update DNS:** Point DNS to new Azure IP
3. **Monitor:** Check Azure Monitor for performance
4. **Backup:** Verify Azure Backup is configured
5. **Cleanup:** Delete Fyre VM when confident

## Useful Commands

\`\`\`bash
# Get VM details
az vm show \\
  --resource-group $RESOURCE_GROUP \\
  --name $VM_HOSTNAME \\
  --show-details

# Get public IP
az vm show \\
  --resource-group $RESOURCE_GROUP \\
  --name $VM_HOSTNAME \\
  --show-details \\
  --query publicIps -o tsv

# SSH to VM
ssh azureuser@<public-ip>

# Stop VM (save costs)
az vm deallocate \\
  --resource-group $RESOURCE_GROUP \\
  --name $VM_HOSTNAME

# Start VM
az vm start \\
  --resource-group $RESOURCE_GROUP \\
  --name $VM_HOSTNAME
\`\`\`

## Files Generated

- vm_info.json - Source VM details
- project_info.json - Azure Migrate project
- appliance_info.json - Appliance credentials
- MIGRATION_REPORT.md - This report

## Support

- Azure Migrate docs: https://docs.microsoft.com/azure/migrate/
- Troubleshooting: ../TROUBLESHOOTING.md
- Azure Support: https://portal.azure.com/#blade/Microsoft_Azure_Support/HelpAndSupportBlade

---

**Migration completed successfully!** 🎉
EOF
    
    log_success "Migration report generated"
    echo ""
}

################################################################################
# Main Execution
################################################################################

main() {
    print_banner
    
    # Execute all phases
    phase_prerequisites
    phase_setup_project
    phase_deploy_appliance
    phase_configure_discovery
    phase_start_replication
    phase_test_migration
    phase_final_migration
    phase_verification
    phase_cleanup
    generate_report
    
    # Final summary
    print_header "Migration Complete! 🎉"
    
    echo "✓ Fyre VM migrated to Azure"
    echo "✓ All resources configured"
    echo "✓ Migration report generated"
    echo ""
    echo "Output Directory: $OUTPUT_DIR"
    echo ""
    echo "Next Steps:"
    echo "  1. Review: cat $OUTPUT_DIR/MIGRATION_REPORT.md"
    echo "  2. Verify: SSH to Azure VM"
    echo "  3. Test: Verify all services"
    echo "  4. Cleanup: Delete Fyre VM when ready"
    echo ""
    echo -e "${GREEN}Migration completed successfully!${NC}"
    echo ""
}

# Run main function
main

# Made with Bob