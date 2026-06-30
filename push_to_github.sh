#!/bin/bash

################################################################################
# Push Migration Files to GitHub
# Purpose: Upload all migration scripts and documentation to GitHub
################################################################################

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "================================================================================"
echo "  Push Migration Files to GitHub"
echo "================================================================================"
echo ""

# Check if git is installed
if ! command -v git &> /dev/null; then
    echo "Installing git..."
    sudo dnf install -y git
fi

# Get GitHub repository URL
echo -e "${BLUE}Enter your GitHub repository URL:${NC}"
echo "Example: https://github.com/yourusername/fyre-azure-migration.git"
read -p "Repository URL: " REPO_URL

if [ -z "$REPO_URL" ]; then
    echo "Error: Repository URL is required"
    exit 1
fi

# Get GitHub credentials
echo ""
echo -e "${BLUE}Enter your GitHub username:${NC}"
read -p "Username: " GIT_USERNAME

echo ""
echo -e "${BLUE}Enter your GitHub Personal Access Token:${NC}"
echo "(Create one at: https://github.com/settings/tokens)"
read -sp "Token: " GIT_TOKEN
echo ""

# Setup git config
git config --global user.name "$GIT_USERNAME"
git config --global user.email "${GIT_USERNAME}@users.noreply.github.com"

# Initialize git repository
echo ""
echo "Initializing git repository..."
cd /opt/migration

if [ ! -d ".git" ]; then
    git init
    echo -e "${GREEN}✓${NC} Git repository initialized"
else
    echo -e "${GREEN}✓${NC} Git repository already exists"
fi

# Create .gitignore
echo ""
echo "Creating .gitignore..."
cat > .gitignore << 'EOF'
# Terraform
.terraform/
*.tfstate
*.tfstate.backup
.terraform.lock.hcl
terraform.tfvars

# SSH Keys
*.pem
*_key
*_key.pub
.ssh/

# Backups
*.tar.gz
/tmp/
fyre_migration_*/

# Logs
*.log
migration_*.txt

# Azure credentials
.azure/

# Sensitive data
*password*
*secret*
*credential*

# OS
.DS_Store
*.swp
*.swo
*~

# IDE
.vscode/
.idea/
EOF

echo -e "${GREEN}✓${NC} .gitignore created"

# Create README if it doesn't exist
if [ ! -f "README.md" ]; then
    echo ""
    echo "Creating README.md..."
    cat > README.md << 'EOF'
# Fyre to Azure VM Migration

Complete migration solution for migrating IBM Workload Automation (TWS) and DB2 from Fyre to Microsoft Azure.

## Overview

This repository contains all scripts, Terraform configurations, and documentation for migrating a Fyre VM to Azure.

### Source Environment
- **Platform**: Fyre (IBM Cloud)
- **OS**: Red Hat Enterprise Linux 9.6
- **vCPUs**: 8
- **RAM**: 14GB
- **Applications**: IBM Workload Automation (TWS) + DB2

### Target Environment
- **Platform**: Microsoft Azure
- **VM Size**: Standard_D8s_v3 (8 vCPU, 32GB RAM)
- **OS**: RHEL 9.6
- **Disks**: 250GB OS + 500GB Data (Premium SSD)

## Repository Structure

```
.
├── azure_terraform/          # Terraform configuration for Azure
│   ├── main.tf              # Main infrastructure definition
│   ├── variables.tf         # Variable definitions
│   ├── outputs.tf           # Output values
│   └── terraform.tfvars.example  # Example configuration
├── backup_fyre_vm.sh        # Backup Fyre VM script
├── restore_to_azure.sh      # Restore on Azure VM script
├── install_azure_cli_rhel.sh    # Install Azure CLI
├── install_terraform_rhel.sh    # Install Terraform
├── fix_azure_nsg.sh         # Fix NSG rules
├── check_fyre_resources.sh  # Analyze Fyre VM resources
├── AZURE_MIGRATION_GUIDE.md # Complete migration guide
├── AZURE_QUICK_START.md     # Quick start guide
├── MIGRATION_COMPLETE_STEPS.md  # Detailed migration steps
└── README.md                # This file
```

## Quick Start

### Prerequisites
- Azure subscription
- Azure CLI
- Terraform >= 1.0
- SSH access to Fyre VM

### Steps

1. **Install Tools**
   ```bash
   ./install_azure_cli_rhel.sh
   ./install_terraform_rhel.sh
   ```

2. **Configure Azure**
   ```bash
   az login
   cd azure_terraform
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars with your values
   ```

3. **Deploy Infrastructure**
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

4. **Backup Fyre VM**
   ```bash
   ./backup_fyre_vm.sh
   ```

5. **Transfer and Restore**
   ```bash
   # Transfer backups to Azure VM
   scp backups/*.tar.gz azureuser@<azure-vm-ip>:/data/migration/
   
   # Restore on Azure VM
   ssh azureuser@<azure-vm-ip>
   sudo ./restore_to_azure.sh
   ```

## Documentation

- **[AZURE_MIGRATION_GUIDE.md](AZURE_MIGRATION_GUIDE.md)** - Complete 545-line migration guide
- **[AZURE_QUICK_START.md](AZURE_QUICK_START.md)** - 5-step quick start
- **[MIGRATION_COMPLETE_STEPS.md](MIGRATION_COMPLETE_STEPS.md)** - Detailed step-by-step record

## Cost Estimation

**Monthly Azure Cost** (East US 2):
- VM (Standard_D8s_v3): ~$350
- OS Disk (250GB Premium): ~$38
- Data Disk (500GB Premium): ~$75
- Networking: ~$15
- **Total**: ~$478/month

**Savings Options**:
- 1-year Reserved Instance: ~$287/month (40% savings)
- 3-year Reserved Instance: ~$191/month (60% savings)

## Support

For issues or questions, please open an issue in this repository.

## License

This project is provided as-is for migration purposes.

---

**Created**: June 2026  
**Last Updated**: June 2026
EOF
    echo -e "${GREEN}✓${NC} README.md created"
fi

# Add files to git
echo ""
echo "Adding files to git..."
git add .

# Check if there are changes to commit
if git diff --staged --quiet; then
    echo -e "${YELLOW}No changes to commit${NC}"
else
    # Commit changes
    echo ""
    echo "Committing changes..."
    git commit -m "Initial commit: Fyre to Azure migration scripts and documentation"
    echo -e "${GREEN}✓${NC} Changes committed"
fi

# Add remote if not exists
if ! git remote | grep -q origin; then
    echo ""
    echo "Adding remote repository..."
    git remote add origin "$REPO_URL"
    echo -e "${GREEN}✓${NC} Remote added"
fi

# Push to GitHub
echo ""
echo "Pushing to GitHub..."
echo "Using URL: https://${GIT_USERNAME}:${GIT_TOKEN}@${REPO_URL#https://}"

# Push with credentials
git push https://${GIT_USERNAME}:${GIT_TOKEN}@${REPO_URL#https://} main 2>&1 || \
git push https://${GIT_USERNAME}:${GIT_TOKEN}@${REPO_URL#https://} master 2>&1 || \
{
    echo ""
    echo "Creating main branch and pushing..."
    git branch -M main
    git push -u https://${GIT_USERNAME}:${GIT_TOKEN}@${REPO_URL#https://} main
}

echo ""
echo "================================================================================"
echo -e "${GREEN}✓ Successfully pushed to GitHub!${NC}"
echo "================================================================================"
echo ""
echo "Repository: $REPO_URL"
echo ""
echo "Files pushed:"
git ls-files | head -20
echo ""
echo "View your repository at:"
echo "$REPO_URL"
echo ""

# Made with Bob
