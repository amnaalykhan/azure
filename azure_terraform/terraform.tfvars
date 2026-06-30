################################################################################
# Azure Terraform Variables - Example Configuration
# 
# Copy this file to terraform.tfvars and update with your values
# cp terraform.tfvars.example terraform.tfvars
################################################################################

# Azure Authentication
subscription_id = "your-subscription-id-here"
tenant_id       = "your-tenant-id-here"

# Resource Configuration
resource_group_name = "rg-tws-db2-migration"
location            = "eastus"  # or centralindia, westeurope, etc.
project_name        = "tws-db2-prod"

# Network Configuration
vnet_address_space = "10.0.0.0/16"
app_subnet_cidr    = "10.0.1.0/24"
db_subnet_cidr     = "10.0.2.0/24"

# Security - Update these with your actual IP ranges
allowed_ssh_cidr = "YOUR_IP_ADDRESS/32"  # Your office/home IP
allowed_tws_cidr = "10.0.0.0/16"         # Internal VNet or specific IPs
allowed_db_cidr  = "10.0.0.0/16"         # Internal VNet only

# VM Configuration
# Based on Fyre VM: 8 vCPU, 14GB RAM, 250GB OS + 500GB Data
vm_size      = "Standard_D8s_v3"  # 8 vCPU, 32GB RAM
admin_username = "azureuser"
ssh_public_key_path = "/root/.ssh/azure_migration_key.pub"  # Use absolute path, not ~

# Disk Configuration
os_disk_size_gb   = 250
os_disk_type      = "Premium_LRS"  # Premium SSD for better performance
data_disk_size_gb = 500
data_disk_type    = "Premium_LRS"

# Optional Features
create_public_ip = true   # Set to false if using VPN/ExpressRoute
enable_backup    = true   # Enable Azure Backup

# Tags
common_tags = {
  Environment = "Production"
  Project     = "TWS-DB2-Migration"
  ManagedBy   = "Terraform"
  Source      = "Fyre"
  Owner       = "Your-Team-Name"
  CostCenter  = "Your-Cost-Center"
}

# Made with Bob
