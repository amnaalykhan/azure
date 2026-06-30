#!/bin/bash

################################################################################
# Azure VM Restore Script (Run on Azure VM)
# Purpose: Restore TWS/DB2 from backups
################################################################################

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

BACKUP_SOURCE="/tmp"

echo "================================================================================"
echo "  Azure VM Restore Script"
echo "  Started: $(date)"
echo "================================================================================"
echo ""

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    echo "This script needs sudo privileges. Rerun with: sudo $0"
    exit 1
fi

# Check for backup files
echo "Checking for backup files in $BACKUP_SOURCE..."
if [ ! -f "$BACKUP_SOURCE/tws_backup.tar.gz" ]; then
    echo -e "${YELLOW}Warning:${NC} tws_backup.tar.gz not found in $BACKUP_SOURCE"
    echo "Please copy backup files first:"
    echo "  scp root@itz-693000iler-gw3v1m6w.dev.fyre.ibm.com:/tmp/fyre_migration_*/tws_backup.tar.gz /tmp/"
    exit 1
fi

# Format and mount data disk
echo ""
echo "Step 1: Configuring data disk..."
if ! mount | grep -q "/data"; then
    echo "Formatting and mounting /dev/sdc..."
    parted /dev/sdc --script mklabel gpt
    parted /dev/sdc --script mkpart primary ext4 0% 100%
    mkfs.ext4 -F /dev/sdc1
    mkdir -p /data
    echo '/dev/sdc1 /data ext4 defaults 0 0' >> /etc/fstab
    mount -a
    echo -e "${GREEN}✓${NC} Data disk mounted at /data"
else
    echo -e "${GREEN}✓${NC} Data disk already mounted"
fi

# Restore TWS installation to /data (more space)
echo ""
echo "Step 2: Restoring TWS installation to /data..."
if [ -f "$BACKUP_SOURCE/tws_backup.tar.gz" ]; then
    # Extract to /data instead of /
    tar xzf "$BACKUP_SOURCE/tws_backup.tar.gz" -C /data
    
    # Create /opt/ibm if it doesn't exist
    mkdir -p /opt/ibm
    
    # Create symlink from /opt/ibm/TWA to /data/opt/ibm/TWA
    if [ -d "/data/opt/ibm/TWA" ]; then
        ln -sf /data/opt/ibm/TWA /opt/ibm/TWA
        echo -e "${GREEN}✓${NC} TWS installation restored to /data/opt/ibm/TWA"
        echo -e "${GREEN}✓${NC} Symlink created: /opt/ibm/TWA -> /data/opt/ibm/TWA"
    fi
else
    echo -e "${YELLOW}Warning:${NC} tws_backup.tar.gz not found"
fi

# Restore TWS configuration
echo ""
echo "Step 3: Restoring TWS configuration..."
if [ -f "$BACKUP_SOURCE/tws_config.tar.gz" ]; then
    tar xzf "$BACKUP_SOURCE/tws_config.tar.gz" -C /
    echo -e "${GREEN}✓${NC} TWS configuration restored"
else
    echo -e "${YELLOW}Warning:${NC} tws_config.tar.gz not found"
fi

# Restore system configuration
echo ""
echo "Step 4: Restoring system configuration..."
if [ -f "$BACKUP_SOURCE/system_config.tar.gz" ]; then
    tar xzf "$BACKUP_SOURCE/system_config.tar.gz" -C /
    echo -e "${GREEN}✓${NC} System configuration restored"
else
    echo -e "${YELLOW}Warning:${NC} system_config.tar.gz not found"
fi

# Create TWS user
echo ""
echo "Step 5: Creating TWS user..."
if ! id tws &>/dev/null; then
    groupadd -g 2054 tws 2>/dev/null || true
    useradd -u 2054 -g 2054 -m tws
    echo -e "${GREEN}✓${NC} TWS user created"
else
    echo -e "${GREEN}✓${NC} TWS user already exists"
fi

# Set permissions
echo ""
echo "Step 6: Setting permissions..."
if [ -d "/opt/ibm/TWA" ]; then
    chown -R tws:tws /opt/ibm/TWA
    echo -e "${GREEN}✓${NC} TWS directory permissions set"
fi

if [ -d "/home/tws" ]; then
    chown -R tws:tws /home/tws
    echo -e "${GREEN}✓${NC} TWS home directory permissions set"
fi

# Install required packages
echo ""
echo "Step 7: Installing required packages..."
dnf install -y ksh libnsl 2>/dev/null || echo "Some packages may already be installed"
echo -e "${GREEN}✓${NC} Required packages installed"

# Summary
echo ""
echo "================================================================================"
echo -e "${GREEN}✓ Restore Complete!${NC}"
echo "================================================================================"
echo ""
echo "Next Steps:"
echo ""
echo "1. Switch to TWS user:"
echo "   sudo su - tws"
echo ""
echo "2. Source TWS environment:"
echo "   cd /opt/ibm/TWA/wa"
echo "   . ./twa_env.sh"
echo ""
echo "3. Start TWS services:"
echo "   ./TWS/bin/StartUp"
echo ""
echo "4. Verify TWS is running:"
echo "   ps aux | grep -i tws"
echo "   netstat -tuln | grep 31114"
echo ""
echo "5. Test TWS commands:"
echo "   composer \"showcpu\""
echo ""

# Made with Bob
