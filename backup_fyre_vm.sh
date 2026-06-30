#!/bin/bash

################################################################################
# Fyre VM Backup Script (Run on Fyre VM)
# Purpose: Create backups locally on Fyre VM
################################################################################

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

BACKUP_DIR="/tmp/fyre_migration_$(date +%Y%m%d_%H%M%S)"

echo "================================================================================"
echo "  Fyre VM Backup Script"
echo "  Started: $(date)"
echo "================================================================================"
echo ""

# Create backup directory
mkdir -p "$BACKUP_DIR"
echo -e "${GREEN}✓${NC} Created backup directory: $BACKUP_DIR"

# Backup TWS installation
echo ""
echo "Backing up TWS installation..."
tar czf "$BACKUP_DIR/tws_backup.tar.gz" /opt/ibm/TWA 2>/dev/null || echo "Warning: Some files may have been skipped"
echo -e "${GREEN}✓${NC} TWS backup complete: $(du -h $BACKUP_DIR/tws_backup.tar.gz | cut -f1)"

# Backup TWS configuration
echo ""
echo "Backing up TWS configuration..."
tar czf "$BACKUP_DIR/tws_config.tar.gz" /home/tws 2>/dev/null || echo "Warning: Some files may have been skipped"
echo -e "${GREEN}✓${NC} TWS config backup complete: $(du -h $BACKUP_DIR/tws_config.tar.gz | cut -f1)"

# Backup system configuration
echo ""
echo "Backing up system configuration..."
tar czf "$BACKUP_DIR/system_config.tar.gz" /etc/hosts /etc/fstab /etc/security/limits.conf /etc/sysctl.conf 2>/dev/null || echo "Warning: Some files may have been skipped"
echo -e "${GREEN}✓${NC} System config backup complete"

# Collect system information
echo ""
echo "Collecting system information..."
cat /etc/os-release > "$BACKUP_DIR/os_release.txt"
df -h > "$BACKUP_DIR/disk_usage.txt"
free -h > "$BACKUP_DIR/memory_info.txt"
lscpu > "$BACKUP_DIR/cpu_info.txt"
ip addr > "$BACKUP_DIR/network_info.txt"
systemctl list-units --type=service --state=running > "$BACKUP_DIR/running_services.txt"
ps aux > "$BACKUP_DIR/processes.txt"
echo -e "${GREEN}✓${NC} System information collected"

# DB2 backup (if accessible)
echo ""
echo "Checking for DB2..."
if command -v db2 &>/dev/null; then
    echo "DB2 found. Attempting backup..."
    su - db2inst1 -c "db2 list database directory" > "$BACKUP_DIR/db2_databases.txt" 2>&1 || echo "Could not list DB2 databases"
    echo -e "${YELLOW}Note:${NC} DB2 backup may need to be done manually by db2inst1 user"
else
    echo "DB2 command not found in PATH"
fi

# Create backup summary
echo ""
echo "Creating backup summary..."
cat > "$BACKUP_DIR/backup_summary.txt" << EOF
Fyre VM Backup Summary
======================
Date: $(date)
Hostname: $(hostname)
Backup Location: $BACKUP_DIR

Files Created:
$(ls -lh $BACKUP_DIR/*.tar.gz 2>/dev/null || echo "No tar.gz files")

Total Backup Size: $(du -sh $BACKUP_DIR | cut -f1)

Next Steps:
1. Copy backups to Azure VM:
   scp $BACKUP_DIR/*.tar.gz azureuser@52.167.58.128:/tmp/

2. Or upload to Azure Storage:
   az storage blob upload-batch --account-name twsdb2proddiag --destination migration-files --source $BACKUP_DIR --pattern "*.tar.gz"
EOF

cat "$BACKUP_DIR/backup_summary.txt"

echo ""
echo "================================================================================"
echo -e "${GREEN}✓ Backup Complete!${NC}"
echo "================================================================================"
echo ""
echo "Backup location: $BACKUP_DIR"
echo "Total size: $(du -sh $BACKUP_DIR | cut -f1)"
echo ""
echo "To transfer to Azure VM:"
echo "  scp $BACKUP_DIR/*.tar.gz azureuser@52.167.58.128:/tmp/"
echo ""

# Made with Bob
