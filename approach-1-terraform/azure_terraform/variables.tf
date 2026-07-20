################################################################################
# Azure Variables for TWS/DB2 Migration
################################################################################

# Azure Subscription
variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Azure Tenant ID"
  type        = string
}

# Resource Group
variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "rg-tws-db2-migration"
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "eastus"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "tws-db2-prod"
}

# Networking
variable "vnet_address_space" {
  description = "Address space for VNet"
  type        = string
  default     = "10.0.0.0/16"
}

variable "app_subnet_cidr" {
  description = "CIDR block for application subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "db_subnet_cidr" {
  description = "CIDR block for database subnet"
  type        = string
  default     = "10.0.2.0/24"
}

# Security
variable "allowed_ssh_cidr" {
  description = "CIDR block allowed for SSH access — set to YOUR_IP/32 before applying"
  type        = string
  # No default: you MUST set this in terraform.tfvars to your IP (curl ifconfig.me)
  # Leaving SSH open to 0.0.0.0/0 exposes the VM to the entire internet.
}

variable "allowed_tws_cidr" {
  description = "CIDR block allowed for TWS port access (31114/31116)"
  type        = string
  default     = "10.0.0.0/16" # Internal VNet only — override if external agents need access
}

variable "allowed_db_cidr" {
  description = "CIDR block allowed for DB2 access"
  type        = string
  default     = "10.0.0.0/16" # Internal VNet only
}

# VM Configuration
variable "vm_size" {
  description = "Azure VM size (based on Fyre: 8 vCPU, 14GB RAM)"
  type        = string
  default     = "Standard_D8s_v3" # 8 vCPU, 32GB RAM

  # Other options:
  # Standard_D4s_v3  - 4 vCPU, 16GB RAM (smaller)
  # Standard_E8s_v3  - 8 vCPU, 64GB RAM (memory optimized)
  # Standard_F8s_v2  - 8 vCPU, 16GB RAM (compute optimized)
}

variable "admin_username" {
  description = "Admin username for the VM"
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

# Disk Configuration
variable "os_disk_size_gb" {
  description = "OS disk size in GB (Fyre has 250GB)"
  type        = number
  default     = 250
}

variable "os_disk_type" {
  description = "OS disk storage type"
  type        = string
  default     = "Premium_LRS" # Premium SSD

  # Options:
  # Standard_LRS    - Standard HDD
  # StandardSSD_LRS - Standard SSD
  # Premium_LRS     - Premium SSD
  # UltraSSD_LRS    - Ultra SSD (highest performance)
}

variable "data_disk_size_gb" {
  description = "Data disk size in GB (Fyre has 500GB vdb)"
  type        = number
  default     = 500
}

variable "data_disk_type" {
  description = "Data disk storage type"
  type        = string
  default     = "Premium_LRS"
}

# Network
variable "create_public_ip" {
  description = "Create public IP for VM"
  type        = bool
  default     = true
}

# Backup
variable "enable_backup" {
  description = "Enable Azure Backup for VM"
  type        = bool
  default     = true
}

# Tags
variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default = {
    Environment = "Production"
    Project     = "TWS-DB2-Migration"
    ManagedBy   = "Terraform"
    Source      = "Fyre"
  }
}

# Made with Bob
