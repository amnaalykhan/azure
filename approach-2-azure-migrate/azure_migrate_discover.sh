#!/bin/bash

################################################################################
# Azure Migrate Automated Discovery Script
# Purpose: Automate Azure Migrate setup and discovery for Fyre VMs
# Usage: ./azure_migrate_discover.sh <fyre-vm-hostname>
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
PROJECT_NAME="fyre-to-azure-migrate"
RESOURCE_GROUP="rg-azure-migrate"
LOCATION="eastus"
OUTPUT_DIR="azure_migrate_discovery_$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$OUTPUT_DIR/discovery.log"

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
    echo -e "${BLUE}--------------------------------------------------------------------------------${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}--------------------------------------------------------------------------------${NC}"
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

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "$1 is not installed. Please install it first."
        exit 1
    fi
}

################################################################################
# Phase 1: Prerequisites Check
################################################################################

check_prerequisites() {
    print_header "Phase 1: Prerequisites Check"
    
    # Create output directory
    mkdir -p "$OUTPUT_DIR"
    
    # Check if VM hostname provided
    if [ -z "$FYRE_VM" ]; then
        log_error "No Fyre VM hostname provided!"
        echo ""
        echo "Usage: $0 <fyre-vm-hostname>"
        echo "Example: $0 itz-693000iler-gw3v1m6w.dev.fyre.ibm.com"
        exit 1
    fi
    
    log_info "Target Fyre VM: $FYRE_VM"
    
    # Check required commands
    log_info "Checking required tools..."
    check_command "az"
    check_command "ssh"
    check_command "jq"
    log_success "All required tools are installed"
    
    # Check Azure CLI login
    log_info "Checking Azure CLI authentication..."
    if ! az account show &> /dev/null; then
        log_error "Not logged into Azure CLI. Run: az login"
        exit 1
    fi
    
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
    log_success "Logged into Azure: $SUBSCRIPTION_NAME"
    
    # Test SSH connection to Fyre VM
    log_info "Testing SSH connection to Fyre VM..."
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$FYRE_VM" "echo 'SSH OK'" &>/dev/null; then
        log_warning "Cannot connect to $FYRE_VM via SSH with key"
        log_info "You may need to enter password during discovery"
    else
        log_success "SSH connection successful"
    fi
    
    echo ""
}

################################################################################
# Phase 2: Discover Fyre VM Configuration
################################################################################

discover_fyre_vm() {
    print_header "Phase 2: Discover Fyre VM Configuration"
    
    print_section "Collecting VM Information"
    
    # Get VM hostname and IP
    log_info "Getting VM details..."
    VM_IP=$(ssh "$FYRE_VM" "hostname -I | awk '{print \$1}'" 2>/dev/null || echo "unknown")
    VM_HOSTNAME=$(ssh "$FYRE_VM" "hostname" 2>/dev/null || echo "$FYRE_VM")
    
    # Get OS information
    log_info "Detecting OS version..."
    OS_INFO=$(ssh "$FYRE_VM" "cat /etc/os-release" 2>/dev/null || echo "")
    OS_NAME=$(echo "$OS_INFO" | grep "^NAME=" | cut -d'"' -f2)
    OS_VERSION=$(echo "$OS_INFO" | grep "^VERSION=" | cut -d'"' -f2)
    
    # Get CPU and Memory
    log_info "Collecting resource information..."
    CPU_COUNT=$(ssh "$FYRE_VM" "nproc" 2>/dev/null || echo "unknown")
    MEMORY_GB=$(ssh "$FYRE_VM" "free -g | grep Mem | awk '{print \$2}'" 2>/dev/null || echo "unknown")
    
    # Get disk information
    log_info "Analyzing disk configuration..."
    DISK_INFO=$(ssh "$FYRE_VM" "lsblk -b -o NAME,SIZE,TYPE,MOUNTPOINT -J" 2>/dev/null || echo "{}")
    
    # Get network interfaces
    log_info "Discovering network interfaces..."
    NETWORK_INFO=$(ssh "$FYRE_VM" "ip -j addr show" 2>/dev/null || echo "[]")
    
    # Get listening ports
    log_info "Scanning listening ports..."
    TCP_PORTS=$(ssh "$FYRE_VM" "ss -tlnp 2>/dev/null | grep LISTEN | awk '{print \$4}' | sed 's/.*://' | sort -u" 2>/dev/null || echo "")
    UDP_PORTS=$(ssh "$FYRE_VM" "ss -ulnp 2>/dev/null | grep -v State | awk '{print \$4}' | sed 's/.*://' | sort -u" 2>/dev/null || echo "")
    
    # Save discovery results
    cat > "$OUTPUT_DIR/vm_discovery.json" <<EOF
{
  "hostname": "$VM_HOSTNAME",
  "ip_address": "$VM_IP",
  "os": {
    "name": "$OS_NAME",
    "version": "$OS_VERSION"
  },
  "resources": {
    "cpu_count": $CPU_COUNT,
    "memory_gb": $MEMORY_GB
  },
  "disk_info": $DISK_INFO,
  "network_info": $NETWORK_INFO,
  "tcp_ports": [$(echo "$TCP_PORTS" | sed 's/^/"/;s/$/"/' | paste -sd,)],
  "udp_ports": [$(echo "$UDP_PORTS" | sed 's/^/"/;s/$/"/' | paste -sd,)]
}
EOF
    
    log_success "VM discovery completed"
    
    # Display summary
    echo ""
    echo "VM Summary:"
    echo "  Hostname: $VM_HOSTNAME"
    echo "  IP Address: $VM_IP"
    echo "  OS: $OS_NAME $OS_VERSION"
    echo "  CPU: $CPU_COUNT cores"
    echo "  Memory: ${MEMORY_GB}GB"
    echo "  TCP Ports: $(echo "$TCP_PORTS" | wc -l) listening"
    echo "  UDP Ports: $(echo "$UDP_PORTS" | wc -l) listening"
    echo ""
}

################################################################################
# Phase 3: Create Azure Migrate Project
################################################################################

create_migrate_project() {
    print_header "Phase 3: Create Azure Migrate Project"
    
    # Check if resource group exists
    log_info "Checking resource group..."
    if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
        log_warning "Resource group $RESOURCE_GROUP already exists"
    else
        log_info "Creating resource group..."
        az group create \
            --name "$RESOURCE_GROUP" \
            --location "$LOCATION" \
            --output none
        log_success "Resource group created"
    fi
    
    # Check if project exists
    log_info "Checking Azure Migrate project..."
    if az resource show \
        --resource-group "$RESOURCE_GROUP" \
        --resource-type "Microsoft.Migrate/migrateProjects" \
        --name "$PROJECT_NAME" &>/dev/null; then
        log_warning "Azure Migrate project $PROJECT_NAME already exists"
    else
        log_info "Creating Azure Migrate project..."
        az resource create \
            --resource-group "$RESOURCE_GROUP" \
            --resource-type "Microsoft.Migrate/migrateProjects" \
            --name "$PROJECT_NAME" \
            --location "$LOCATION" \
            --properties '{"publicNetworkAccess":"Enabled"}' \
            --output none
        log_success "Azure Migrate project created"
    fi
    
    # Save project details
    cat > "$OUTPUT_DIR/migrate_project.json" <<EOF
{
  "project_name": "$PROJECT_NAME",
  "resource_group": "$RESOURCE_GROUP",
  "location": "$LOCATION",
  "subscription_id": "$SUBSCRIPTION_ID"
}
EOF
    
    echo ""
    log_success "Azure Migrate project ready"
    echo ""
}

################################################################################
# Phase 4: Generate Azure Migrate Configuration
################################################################################

generate_migrate_config() {
    print_header "Phase 4: Generate Azure Migrate Configuration"
    
    # Recommend Azure VM size based on Fyre VM
    log_info "Recommending Azure VM size..."
    
    if [ "$CPU_COUNT" -ge 8 ]; then
        RECOMMENDED_SIZE="Standard_D8s_v3"
    elif [ "$CPU_COUNT" -ge 4 ]; then
        RECOMMENDED_SIZE="Standard_D4s_v3"
    else
        RECOMMENDED_SIZE="Standard_D2s_v3"
    fi
    
    # Calculate total disk size
    TOTAL_DISK_GB=$(ssh "$FYRE_VM" "df -BG / | tail -1 | awk '{print \$2}' | sed 's/G//'" 2>/dev/null || echo "250")
    
    # Generate migration configuration
    cat > "$OUTPUT_DIR/migration_config.json" <<EOF
{
  "source_vm": {
    "hostname": "$VM_HOSTNAME",
    "ip_address": "$VM_IP",
    "os": "$OS_NAME $OS_VERSION",
    "cpu_count": $CPU_COUNT,
    "memory_gb": $MEMORY_GB,
    "disk_gb": $TOTAL_DISK_GB
  },
  "target_azure": {
    "recommended_vm_size": "$RECOMMENDED_SIZE",
    "resource_group": "$RESOURCE_GROUP",
    "location": "$LOCATION",
    "os_disk_size_gb": $TOTAL_DISK_GB
  },
  "migration_settings": {
    "replication_enabled": true,
    "test_migration_recommended": true,
    "backup_enabled": true
  }
}
EOF
    
    log_success "Migration configuration generated"
    
    echo ""
    echo "Recommended Azure Configuration:"
    echo "  VM Size: $RECOMMENDED_SIZE"
    echo "  OS Disk: ${TOTAL_DISK_GB}GB"
    echo "  Location: $LOCATION"
    echo ""
}

################################################################################
# Phase 5: Generate Setup Instructions
################################################################################

generate_instructions() {
    print_header "Phase 5: Generate Setup Instructions"
    
    cat > "$OUTPUT_DIR/NEXT_STEPS.md" <<'EOF'
# Azure Migrate - Next Steps

## Discovery Complete! ✓

Your Fyre VM has been discovered and Azure Migrate project is ready.

## What Was Created:

1. **Azure Migrate Project**: `fyre-to-azure-migrate`
2. **Resource Group**: `rg-azure-migrate`
3. **Discovery Files**: All VM details captured

## Next Steps:

### Step 1: Deploy Azure Migrate Appliance (30-60 min)

The appliance is needed to manage the migration process.

**Option A: Deploy in Azure (Recommended)**
```bash
# Run the automated appliance deployment script
./deploy_migrate_appliance.sh
```

**Option B: Manual Deployment**
1. Go to Azure Portal → Azure Migrate
2. Click "Servers, databases and web apps"
3. Click "Discover" → Follow wizard
4. Deploy appliance VM

### Step 2: Configure Discovery (15 min)

```bash
# Run the automated configuration script
./configure_migrate_discovery.sh
```

Or manually:
1. Connect to appliance
2. Add Fyre VM credentials
3. Start discovery

### Step 3: Start Replication (1-2 hours)

```bash
# Run the automated replication script
./start_migrate_replication.sh
```

Or manually:
1. Wait for discovery to complete
2. Review assessment
3. Start replication
4. Monitor progress

### Step 4: Test Migration (30 min, optional)

```bash
# Run the test migration script
./test_migrate_migration.sh
```

### Step 5: Final Migration (5-10 min)

```bash
# Run the final migration script
./complete_migrate_migration.sh
```

## Quick Commands:

```bash
# Check project status
az resource show \
  --resource-group rg-azure-migrate \
  --resource-type "Microsoft.Migrate/migrateProjects" \
  --name fyre-to-azure-migrate

# View discovered VMs (after appliance setup)
az migrate machine list \
  --resource-group rg-azure-migrate \
  --project-name fyre-to-azure-migrate

# Check replication status
az migrate replication list \
  --resource-group rg-azure-migrate \
  --project-name fyre-to-azure-migrate
```

## Files Generated:

- `vm_discovery.json` - Complete VM details
- `migration_config.json` - Recommended Azure configuration
- `migrate_project.json` - Azure Migrate project details
- `NEXT_STEPS.md` - This file

## Need Help?

- Check `../SETUP_GUIDE.md` for detailed instructions
- Check `../TROUBLESHOOTING.md` for common issues
- Run `./check_migrate_prerequisites.sh` to verify setup

## Estimated Timeline:

- Appliance deployment: 30-60 min
- Discovery: 15-30 min
- Replication: 1-2 hours
- Test migration: 30 min (optional)
- Final migration: 5-10 min

**Total: 2-4 hours (mostly automated)**

---

**Ready to continue? Run: `./deploy_migrate_appliance.sh`**
EOF
    
    log_success "Setup instructions generated"
    echo ""
}

################################################################################
# Phase 6: Summary and Next Steps
################################################################################

show_summary() {
    print_header "Discovery Complete!"
    
    echo "✓ Fyre VM discovered: $VM_HOSTNAME"
    echo "✓ Azure Migrate project created: $PROJECT_NAME"
    echo "✓ Configuration generated"
    echo ""
    echo "Output Directory: $OUTPUT_DIR"
    echo ""
    echo "Files Created:"
    echo "  - vm_discovery.json (VM details)"
    echo "  - migration_config.json (Azure recommendations)"
    echo "  - migrate_project.json (Project details)"
    echo "  - NEXT_STEPS.md (What to do next)"
    echo ""
    echo -e "${CYAN}Next Steps:${NC}"
    echo "  1. Review: cat $OUTPUT_DIR/NEXT_STEPS.md"
    echo "  2. Deploy appliance: ./deploy_migrate_appliance.sh"
    echo "  3. Or follow manual steps in SETUP_GUIDE.md"
    echo ""
    echo -e "${GREEN}Discovery completed successfully!${NC}"
    echo ""
}

################################################################################
# Main Execution
################################################################################

main() {
    clear
    print_header "Azure Migrate Automated Discovery"
    
    check_prerequisites
    discover_fyre_vm
    create_migrate_project
    generate_migrate_config
    generate_instructions
    show_summary
}

# Run main function
main

# Made with Bob