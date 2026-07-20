#!/bin/bash

################################################################################
# Fix Azure NSG to Allow Your IP
# Purpose: Update NSG to allow SSH from your current IP
################################################################################

set -e

echo "================================================================================"
echo "  Azure NSG Fix Script"
echo "  This will update the NSG to allow SSH from your current IP"
echo "================================================================================"
echo ""

# Get your current public IP
echo "Detecting your public IP address..."
YOUR_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || curl -s ipecho.net/plain)

if [ -z "$YOUR_IP" ]; then
    echo "Error: Could not detect your public IP address"
    echo "Please run manually:"
    echo "  az network nsg rule update -g rg-tws-db2-migration --nsg-name tws-db2-prod-app-nsg -n SSH --source-address-prefixes YOUR_IP/32"
    exit 1
fi

echo "Your public IP: $YOUR_IP"
echo ""

# Update NSG rule
echo "Updating Azure NSG to allow SSH from $YOUR_IP/32..."
az network nsg rule update \
    --resource-group rg-tws-db2-migration \
    --nsg-name tws-db2-prod-app-nsg \
    --name SSH \
    --source-address-prefixes "$YOUR_IP/32"

echo ""
echo "✓ NSG rule updated successfully!"
echo ""
echo "You can now SSH to the Azure VM:"
echo "  ssh azureuser@52.167.58.128"
echo ""
echo "If you still can't connect, wait 30 seconds for the rule to propagate."
echo ""

# Made with Bob
