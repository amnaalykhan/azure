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
