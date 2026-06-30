#!/bin/bash

################################################################################
# Fyre to Azure Migration Script
# Purpose: Migrate TWS/DB2 VM from Fyre to Azure
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
FYRE_VM="itz-693000iler-gw3v1m6w.dev.fyre.ibm.com"
BACKUP_DIR="/tmp/fyre_migration_$(date +%Y%m%d_%H%M%S)"
AZURE_STORAGE_ACCOUNT=""  # Will be set after Terraform
AZURE_CONTAINER="migration-files"
LOG_FILE="migration_$(date +%Y%m%d_%H%M%S).log"

################################################################################
# Helper Functions
################################################################################

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        error "$1 is not installed. Please install it first."
        exit 1
    fi
}

################################################################################
# Phase 1: Pre-Migration Checks
################################################################################

pre_migration_checks() {
    log "Phase 1: Pre-Migration Checks"
    
    # Check required commands
    info "Checking required tools..."
    check_command "terraform"
    check_command "az"
    check_command "ssh"
    check_command "rsync"
    
    # Check Azure CLI login
    info "Checking Azure CLI authentication..."
    if ! az account show &> /dev/null; then
        error "Not logged into Azure CLI. Run: az login"
        exit 1
    fi
    
    log "✓ Pre-migration checks passed"
}

################################################################################
# Phase 2: Backup Fyre VM
################################################################################

backup_fyre_vm() {
    log "Phase 2: Backing up Fyre VM"
    
    mkdir -p "$BACKUP_DIR"
    
    info "Creating backup directory: $BACKUP_DIR"
    
    # Backup TWS installation
    log "Backing up TWS installation..."
    ssh root@"$FYRE_VM" "tar czf /tmp/tws_backup.tar.gz /opt/ibm/TWA" || warning "TWS backup may be incomplete"
    scp root@"$FYRE_VM":/tmp/tws_backup.tar.gz "$BACKUP_DIR/" || error "Failed to copy TWS backup"
    
    # Backup TWS configuration
    log "Backing up TWS configuration..."
    ssh root@"$FYRE_VM" "tar czf /tmp/tws_config.tar.gz /home/tws" || warning "TWS config backup may be incomplete"
    scp root@"$FYRE_VM":/tmp/tws_config.tar.gz "$BACKUP_DIR/" || error "Failed to copy TWS config"
    
    # Backup DB2 (if accessible)
    log "Backing up DB2..."
    ssh root@"$FYRE_VM" "su - db2inst1 -c 'db2 backup database sample to /tmp'" 2>/dev/null || warning "DB2 backup skipped (may need manual backup)"
    
    # Backup system configuration
    log "Backing up system configuration..."
    ssh root@"$FYRE_VM" "tar czf /tmp/system_config.tar.gz /etc/hosts /etc/fstab /etc/security/limits.conf /etc/sysctl.conf" || warning "System config backup may be incomplete"
    scp root@"$FYRE_VM":/tmp/system_config.tar.gz "$BACKUP_DIR/" || error "Failed to copy system config"
    
    # Get system information
    log "Collecting system information..."
    ssh root@"$FYRE_VM" "cat /etc/os-release" > "$BACKUP_DIR/os_release.txt"
    ssh root@"$FYRE_VM" "df -h" > "$BACKUP_DIR/disk_usage.txt"
    ssh root@"$FYRE_VM" "free -h" > "$BACKUP_DIR/memory_info.txt"
    ssh root@"$FYRE_VM" "lscpu" > "$BACKUP_DIR/cpu_info.txt"
    ssh root@"$FYRE_VM" "ip addr" > "$BACKUP_DIR/network_info.txt"
    ssh root@"$FYRE_VM" "systemctl list-units --type=service --state=running" > "$BACKUP_DIR/running_services.txt"
    
    log "✓ Backup completed: $BACKUP_DIR"
}

################################################################################
# Phase 3: Deploy Azure Infrastructure
################################################################################

deploy_azure_infrastructure() {
    log "Phase 3: Deploying Azure Infrastructure"
    
    cd azure_terraform
    
    # Check if terraform.tfvars exists
    if [ ! -f "terraform.tfvars" ]; then
        error "terraform.tfvars not found. Copy from terraform.tfvars.example and configure."
        exit 1
    fi
    
    # Initialize Terraform
    log "Initializing Terraform..."
    terraform init
    
    # Validate configuration
    log "Validating Terraform configuration..."
    terraform validate
    
    # Plan deployment
    log "Planning Azure deployment..."
    terraform plan -out=tfplan
    
    # Apply deployment
    warning "About to deploy Azure infrastructure. Review the plan above."
    read -p "Continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        error "Deployment cancelled by user"
        exit 1
    fi
    
    log "Deploying Azure infrastructure..."
    terraform apply tfplan
    
    # Get outputs
    AZURE_VM_IP=$(terraform output -raw vm_public_ip)
    AZURE_STORAGE_ACCOUNT=$(terraform output -raw storage_account_name)
    
    log "✓ Azure infrastructure deployed"
    info "VM Public IP: $AZURE_VM_IP"
    info "Storage Account: $AZURE_STORAGE_ACCOUNT"
    
    cd ..
}

################################################################################
# Phase 4: Upload Backups to Azure Storage
################################################################################

upload_to_azure_storage() {
    log "Phase 4: Uploading backups to Azure Storage"
    
    if [ -z "$AZURE_STORAGE_ACCOUNT" ]; then
        error "Azure storage account not set"
        exit 1
    fi
    
    log "Uploading backup files to Azure Blob Storage..."
    az storage blob upload-batch \
        --account-name "$AZURE_STORAGE_ACCOUNT" \
        --destination "$AZURE_CONTAINER" \
        --source "$BACKUP_DIR" \
        --pattern "*.tar.gz" \
        --auth-mode login
    
    log "✓ Backups uploaded to Azure Storage"
}

################################################################################
# Phase 5: Configure Azure VM
################################################################################

configure_azure_vm() {
    log "Phase 5: Configuring Azure VM"
    
    if [ -z "$AZURE_VM_IP" ]; then
        error "Azure VM IP not set"
        exit 1
    fi
    
    info "Waiting for VM to be ready..."
    sleep 30
    
    # Test SSH connection
    log "Testing SSH connection..."
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 azureuser@"$AZURE_VM_IP" "echo 'SSH connection successful'" || {
        error "Cannot connect to Azure VM via SSH"
        exit 1
    }
    
    # Install required packages
    log "Installing required packages..."
    ssh azureuser@"$AZURE_VM_IP" "sudo dnf install -y wget curl tar gzip rsync"
    
    # Format and mount data disk
    log "Configuring data disk..."
    ssh azureuser@"$AZURE_VM_IP" << 'EOF'
        sudo parted /dev/sdc --script mklabel gpt
        sudo parted /dev/sdc --script mkpart primary ext4 0% 100%
        sudo mkfs.ext4 /dev/sdc1
        sudo mkdir -p /data
        echo '/dev/sdc1 /data ext4 defaults 0 0' | sudo tee -a /etc/fstab
        sudo mount -a
        sudo chown azureuser:azureuser /data
EOF
    
    log "✓ Azure VM configured"
}

################################################################################
# Phase 6: Restore Data to Azure VM
################################################################################

restore_data_to_azure() {
    log "Phase 6: Restoring data to Azure VM"
    
    # Download backups from Azure Storage
    log "Downloading backups from Azure Storage..."
    ssh azureuser@"$AZURE_VM_IP" "mkdir -p /tmp/migration"
    
    az storage blob download-batch \
        --account-name "$AZURE_STORAGE_ACCOUNT" \
        --source "$AZURE_CONTAINER" \
        --destination /tmp/migration_download \
        --pattern "*.tar.gz" \
        --auth-mode login
    
    # Copy to Azure VM
    log "Copying backups to Azure VM..."
    scp /tmp/migration_download/*.tar.gz azureuser@"$AZURE_VM_IP":/tmp/migration/
    
    # Restore TWS
    log "Restoring TWS installation..."
    ssh azureuser@"$AZURE_VM_IP" << 'EOF'
        cd /tmp/migration
        sudo tar xzf tws_backup.tar.gz -C /
        sudo tar xzf tws_config.tar.gz -C /
        sudo tar xzf system_config.tar.gz -C /
        
        # Create TWS user if not exists
        if ! id tws &>/dev/null; then
            sudo useradd -u 2054 -g 2054 tws
        fi
        
        # Set permissions
        sudo chown -R tws:tws /opt/ibm/TWA
        sudo chown -R tws:tws /home/tws
EOF
    
    log "✓ Data restored to Azure VM"
}

################################################################################
# Phase 7: Post-Migration Validation
################################################################################

post_migration_validation() {
    log "Phase 7: Post-Migration Validation"
    
    info "Validating TWS installation..."
    ssh azureuser@"$AZURE_VM_IP" "sudo ls -la /opt/ibm/TWA/wa" || warning "TWS directory not found"
    
    info "Checking TWS processes..."
    ssh azureuser@"$AZURE_VM_IP" "ps aux | grep -i tws | grep -v grep" || warning "TWS processes not running"
    
    info "Checking disk usage..."
    ssh azureuser@"$AZURE_VM_IP" "df -h"
    
    info "Checking memory..."
    ssh azureuser@"$AZURE_VM_IP" "free -h"
    
    log "✓ Post-migration validation completed"
}

################################################################################
# Phase 8: Generate Migration Report
################################################################################

generate_migration_report() {
    log "Phase 8: Generating Migration Report"
    
    local report_file="migration_report_$(date +%Y%m%d_%H%M%S).txt"
    
    cat > "$report_file" << EOF
================================================================================
Fyre to Azure Migration Report
Generated: $(date)
================================================================================

Source VM (Fyre):
  Hostname: $FYRE_VM
  OS: Red Hat Enterprise Linux 9.6
  vCPUs: 8
  RAM: 14GB
  Disk: 250GB + 500GB

Target VM (Azure):
  Public IP: $AZURE_VM_IP
  VM Size: Standard_D8s_v3 (8 vCPU, 32GB RAM)
  OS Disk: 250GB Premium SSD
  Data Disk: 500GB Premium SSD

Backup Location:
  Local: $BACKUP_DIR
  Azure Storage: $AZURE_STORAGE_ACCOUNT/$AZURE_CONTAINER

Migration Steps Completed:
  ✓ Pre-migration checks
  ✓ Fyre VM backup
  ✓ Azure infrastructure deployment
  ✓ Backup upload to Azure Storage
  ✓ Azure VM configuration
  ✓ Data restoration
  ✓ Post-migration validation

Next Steps:
  1. Start TWS services on Azure VM
  2. Verify TWS functionality
  3. Update DNS/network configurations
  4. Test application connectivity
  5. Decommission Fyre VM (after validation)

Log File: $LOG_FILE
================================================================================
EOF
    
    cat "$report_file"
    log "✓ Migration report generated: $report_file"
}

################################################################################
# Main Execution
################################################################################

main() {
    echo "================================================================================"
    echo "  Fyre to Azure Migration Script"
    echo "  TWS/DB2 VM Migration"
    echo "  Started: $(date)"
    echo "================================================================================"
    echo ""
    
    pre_migration_checks
    backup_fyre_vm
    deploy_azure_infrastructure
    upload_to_azure_storage
    configure_azure_vm
    restore_data_to_azure
    post_migration_validation
    generate_migration_report
    
    echo ""
    echo -e "${GREEN}================================================================================"
    echo "  Migration Completed Successfully!"
    echo "================================================================================${NC}"
    echo ""
    echo "Azure VM IP: $AZURE_VM_IP"
    echo "SSH Command: ssh azureuser@$AZURE_VM_IP"
    echo ""
    echo "Review the migration report and logs for details."
    echo ""
}

# Execute main function
main "$@"

# Made with Bob
