################################################################################
# Azure Outputs
################################################################################

output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.main.name
}

output "resource_group_location" {
  description = "Location of the resource group"
  value       = azurerm_resource_group.main.location
}

output "vm_id" {
  description = "ID of the virtual machine"
  value       = azurerm_linux_virtual_machine.tws_db2.id
}

output "vm_name" {
  description = "Name of the virtual machine"
  value       = azurerm_linux_virtual_machine.tws_db2.name
}

output "vm_private_ip" {
  description = "Private IP address of the VM"
  value       = azurerm_network_interface.vm.private_ip_address
}

output "vm_public_ip" {
  description = "Public IP address of the VM (if created)"
  value       = var.create_public_ip ? azurerm_public_ip.vm[0].ip_address : "No public IP"
}

output "ssh_connection_string" {
  description = "SSH connection string"
  value       = var.create_public_ip ? "ssh ${var.admin_username}@${azurerm_public_ip.vm[0].ip_address}" : "ssh ${var.admin_username}@${azurerm_network_interface.vm.private_ip_address}"
}

output "vnet_id" {
  description = "ID of the virtual network"
  value       = azurerm_virtual_network.main.id
}

output "vnet_name" {
  description = "Name of the virtual network"
  value       = azurerm_virtual_network.main.name
}

output "app_subnet_id" {
  description = "ID of the application subnet"
  value       = azurerm_subnet.app.id
}

output "db_subnet_id" {
  description = "ID of the database subnet"
  value       = azurerm_subnet.db.id
}

output "nsg_id" {
  description = "ID of the network security group"
  value       = azurerm_network_security_group.app.id
}

output "os_disk_id" {
  description = "ID of the OS disk"
  value       = azurerm_linux_virtual_machine.tws_db2.os_disk[0].name
}

output "data_disk_id" {
  description = "ID of the data disk"
  value       = azurerm_managed_disk.data.id
}

output "storage_account_name" {
  description = "Name of the storage account"
  value       = azurerm_storage_account.diag.name
}

output "storage_account_primary_blob_endpoint" {
  description = "Primary blob endpoint of the storage account"
  value       = azurerm_storage_account.diag.primary_blob_endpoint
}

output "backup_vault_name" {
  description = "Name of the backup vault (if enabled)"
  value       = var.enable_backup ? azurerm_recovery_services_vault.main[0].name : "Backup not enabled"
}

output "migration_summary" {
  description = "Migration summary information"
  value = {
    vm_size           = var.vm_size
    os_disk_size_gb   = var.os_disk_size_gb
    data_disk_size_gb = var.data_disk_size_gb
    private_ip        = azurerm_network_interface.vm.private_ip_address
    public_ip         = var.create_public_ip ? azurerm_public_ip.vm[0].ip_address : "None"
    backup_enabled    = var.enable_backup
    resource_group    = azurerm_resource_group.main.name
    location          = azurerm_resource_group.main.location
  }
}

# Made with Bob
