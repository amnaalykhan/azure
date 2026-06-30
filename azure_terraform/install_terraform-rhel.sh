#!/bin/bash

################################################################################
# Terraform Installation Script for RHEL 9
################################################################################

set -e

echo "Installing Terraform on RHEL 9..."

# Install required packages
sudo dnf install -y wget unzip

# Get latest Terraform version (or specify a version)
TERRAFORM_VERSION="1.6.6"  # Update this to latest stable version if needed

# Download Terraform
echo "Downloading Terraform ${TERRAFORM_VERSION}..."
cd /tmp
wget https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip

# Unzip and install
echo "Installing Terraform..."
unzip -o terraform_${TERRAFORM_VERSION}_linux_amd64.zip
sudo mv terraform /usr/local/bin/
sudo chmod +x /usr/local/bin/terraform

# Cleanup
rm terraform_${TERRAFORM_VERSION}_linux_amd64.zip

# Verify installation
echo ""
echo "Verifying installation..."
terraform version

echo ""
echo "✓ Terraform installed successfully!"
echo ""
echo "Location: /usr/local/bin/terraform"
echo "Version: $(terraform version | head -1)"
echo ""
echo "Next steps:"
echo "  1. cd azure_terraform"
echo "  2. terraform init"
echo "  3. terraform plan"
echo ""

# Made with Bob
