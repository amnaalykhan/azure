################################################################################
# Azure Terraform Configuration for Fyre TWS/DB2 VM Migration
# 
# This configuration creates:
# - Resource Group
# - Virtual Network with subnets
# - Network Security Groups
# - Virtual Machine (RHEL 9.6)
# - Managed Disks (OS + Data)
# - Network Interface
# - Public IP (optional)
# - Storage Account for backups
################################################################################

terraform {
  required_version = ">= 1.0"
  
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    
    virtual_machine {
      delete_os_disk_on_deletion     = true
      graceful_shutdown              = true
      skip_shutdown_and_force_delete = false
    }
  }
  
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}

################################################################################
# Resource Group
################################################################################

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  
  tags = merge(
    var.common_tags,
    {
      Purpose = "TWS-DB2-Migration"
    }
  )
}

################################################################################
# Virtual Network
################################################################################

resource "azurerm_virtual_network" "main" {
  name                = "${var.project_name}-vnet"
  address_space       = [var.vnet_address_space]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  
  tags = var.common_tags
}

resource "azurerm_subnet" "app" {
  name                 = "${var.project_name}-app-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.app_subnet_cidr]
}

resource "azurerm_subnet" "db" {
  name                 = "${var.project_name}-db-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.db_subnet_cidr]
}

################################################################################
# Network Security Groups
################################################################################

# Application/TWS NSG
resource "azurerm_network_security_group" "app" {
  name                = "${var.project_name}-app-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  
  # SSH Access
  security_rule {
    name                       = "SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_ssh_cidr
    destination_address_prefix = "*"
  }
  
  # TWS Master Port
  security_rule {
    name                       = "TWS-Master"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "31114"
    source_address_prefix      = var.allowed_tws_cidr
    destination_address_prefix = "*"
  }
  
  # TWS Agent Port
  security_rule {
    name                       = "TWS-Agent"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "31116"
    source_address_prefix      = var.allowed_tws_cidr
    destination_address_prefix = "*"
  }
  
  # DB2 Port
  security_rule {
    name                       = "DB2"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "50000"
    source_address_prefix      = var.allowed_db_cidr
    destination_address_prefix = "*"
  }
  
  # Outbound - Allow all
  security_rule {
    name                       = "AllowAllOutbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  
  tags = var.common_tags
}

# Associate NSG with App Subnet
resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

################################################################################
# Public IP (Optional)
################################################################################

resource "azurerm_public_ip" "vm" {
  count               = var.create_public_ip ? 1 : 0
  name                = "${var.project_name}-vm-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  
  tags = var.common_tags
}

################################################################################
# Network Interface
################################################################################

resource "azurerm_network_interface" "vm" {
  name                = "${var.project_name}-vm-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = var.create_public_ip ? azurerm_public_ip.vm[0].id : null
  }
  
  tags = var.common_tags
}

################################################################################
# Virtual Machine
################################################################################

resource "azurerm_linux_virtual_machine" "tws_db2" {
  name                = "${var.project_name}-vm"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  size                = var.vm_size
  admin_username      = var.admin_username
  
  network_interface_ids = [
    azurerm_network_interface.vm.id,
  ]
  
  # SSH Key Authentication
  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key_path)
  }
  
  # Disable password authentication
  disable_password_authentication = true
  
  # OS Disk
  os_disk {
    name                 = "${var.project_name}-os-disk"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }
  
  # RHEL 9.6 Image
  source_image_reference {
    publisher = "RedHat"
    offer     = "RHEL"
    sku       = "96-gen2"
    version   = "latest"
  }
  
  # Boot diagnostics
  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.diag.primary_blob_endpoint
  }
  
  tags = merge(
    var.common_tags,
    {
      Application = "TWS-DB2"
      OS          = "RHEL-9.6"
    }
  )
}

################################################################################
# Data Disks
################################################################################

# Data Disk for TWS/DB2
resource "azurerm_managed_disk" "data" {
  name                 = "${var.project_name}-data-disk"
  location             = azurerm_resource_group.main.location
  resource_group_name  = azurerm_resource_group.main.name
  storage_account_type = var.data_disk_type
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size_gb
  
  tags = var.common_tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  managed_disk_id    = azurerm_managed_disk.data.id
  virtual_machine_id = azurerm_linux_virtual_machine.tws_db2.id
  lun                = 0
  caching            = "ReadWrite"
}

################################################################################
# Storage Account for Diagnostics and Backups
################################################################################

resource "azurerm_storage_account" "diag" {
  name                     = "${replace(var.project_name, "-", "")}diag"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  
  tags = var.common_tags
}

resource "azurerm_storage_container" "backups" {
  name                  = "tws-backups"
  storage_account_name  = azurerm_storage_account.diag.name
  container_access_type = "private"
}

resource "azurerm_storage_container" "migration" {
  name                  = "migration-files"
  storage_account_name  = azurerm_storage_account.diag.name
  container_access_type = "private"
}

################################################################################
# Azure Backup (Optional)
################################################################################

resource "azurerm_recovery_services_vault" "main" {
  count               = var.enable_backup ? 1 : 0
  name                = "${var.project_name}-vault"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard"
  
  soft_delete_enabled = true
  
  tags = var.common_tags
}

resource "azurerm_backup_policy_vm" "daily" {
  count               = var.enable_backup ? 1 : 0
  name                = "${var.project_name}-backup-policy"
  resource_group_name = azurerm_resource_group.main.name
  recovery_vault_name = azurerm_recovery_services_vault.main[0].name
  
  timezone = "UTC"
  
  backup {
    frequency = "Daily"
    time      = "23:00"
  }
  
  retention_daily {
    count = 30
  }
  
  retention_weekly {
    count    = 12
    weekdays = ["Sunday"]
  }
  
  retention_monthly {
    count    = 12
    weekdays = ["Sunday"]
    weeks    = ["First"]
  }
}

resource "azurerm_backup_protected_vm" "vm" {
  count               = var.enable_backup ? 1 : 0
  resource_group_name = azurerm_resource_group.main.name
  recovery_vault_name = azurerm_recovery_services_vault.main[0].name
  source_vm_id        = azurerm_linux_virtual_machine.tws_db2.id
  backup_policy_id    = azurerm_backup_policy_vm.daily[0].id
}

# Made with Bob
