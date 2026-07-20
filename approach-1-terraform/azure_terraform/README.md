# Terraform — Azure Infrastructure Reference

All variables, resources, and outputs for the Azure infrastructure deployed by Approach 1.

---

## Setup

```bash
cd azure_terraform

# Copy and edit the config
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars

# Deploy
terraform init
terraform plan
terraform apply

# Get outputs
terraform output
```

---

## terraform.tfvars — All Variables

### Required (no defaults — must fill these in)

| Variable | Description | Example |
|----------|-------------|---------|
| `subscription_id` | Azure Subscription ID | `630b0990-5eac-49a6-bc6a-70c52c6b42e6` |
| `tenant_id` | Azure Tenant ID | `61363c43-8420-43ca-8f82-801627e16cdf` |

```bash
# Get both values
az account show --query "{subscription_id:id, tenant_id:tenantId}" -o table
```

### Network

| Variable | Default | Description |
|----------|---------|-------------|
| `location` | `eastus` | Azure region |
| `resource_group_name` | `rg-tws-db2-migration` | Resource group name |
| `project_name` | `tws-db2-prod` | Prefix for all resource names |
| `vnet_address_space` | `10.0.0.0/16` | VNet CIDR |
| `app_subnet_cidr` | `10.0.1.0/24` | Application subnet |
| `db_subnet_cidr` | `10.0.2.0/24` | Database subnet |

### Security

| Variable | Default | Description |
|----------|---------|-------------|
| `allowed_ssh_cidr` | `0.0.0.0/0` | IPs allowed SSH access — **change to your IP** |
| `allowed_tws_cidr` | `0.0.0.0/0` | IPs allowed TWS port access |
| `allowed_db_cidr` | `10.0.0.0/16` | IPs allowed DB2 port access |

```bash
# Get your current IP for allowed_ssh_cidr
curl -s ifconfig.me
# Use as: allowed_ssh_cidr = "203.0.113.5/32"
```

### VM

| Variable | Default | Description |
|----------|---------|-------------|
| `vm_size` | `Standard_D8s_v3` | Azure VM size (8 vCPU, 32GB RAM) |
| `admin_username` | `azureuser` | VM admin username |
| `ssh_public_key_path` | `~/.ssh/id_rsa.pub` | Path to your SSH public key |

```bash
# List available VM sizes in eastus
az vm list-sizes --location eastus --query "[?numberOfCores<=8].[name, numberOfCores, memoryInMb]" -o table

# Common sizes
# Standard_D2s_v3  — 2 vCPU,  8GB RAM  (~$70/month)
# Standard_D4s_v3  — 4 vCPU, 16GB RAM  (~$140/month)
# Standard_D8s_v3  — 8 vCPU, 32GB RAM  (~$280/month)
# Standard_E4s_v3  — 4 vCPU, 32GB RAM  (memory-optimised)
```

### Disks

| Variable | Default | Description |
|----------|---------|-------------|
| `os_disk_size_gb` | `250` | OS disk size in GB |
| `os_disk_type` | `Premium_LRS` | OS disk type |
| `data_disk_size_gb` | `500` | Data disk size in GB |
| `data_disk_type` | `Premium_LRS` | Data disk type |

Disk type options:
- `Standard_LRS` — HDD (~$5/100GB)
- `StandardSSD_LRS` — Standard SSD (~$8/100GB)
- `Premium_LRS` — Premium SSD (~$15/100GB) ← recommended

### Features

| Variable | Default | Description |
|----------|---------|-------------|
| `create_public_ip` | `true` | Create public IP for SSH access |
| `enable_backup` | `true` | Enable Azure Backup (30-day retention) |

---

## Resources Created

| Resource | Name | Description |
|----------|------|-------------|
| Resource Group | `var.resource_group_name` | Container for all resources |
| VNet | `<project>-vnet` | Virtual network |
| App Subnet | `<project>-app-subnet` | 10.0.1.0/24 |
| DB Subnet | `<project>-db-subnet` | 10.0.2.0/24 |
| NSG | `<project>-app-nsg` | SSH + TWS + DB2 rules |
| Public IP | `<project>-vm-pip` | Static public IP |
| NIC | `<project>-vm-nic` | Network interface |
| VM | `<project>-vm` | Linux VM (RHEL 9.6) |
| OS Disk | `<project>-os-disk` | Premium SSD |
| Data Disk | `<project>-data-disk` | Premium SSD |
| Storage Account | `<project>diag` | Boot diagnostics + backups |
| Recovery Vault | `<project>-vault` | Azure Backup (if enabled) |

---

## Outputs

```bash
terraform output                  # Show all outputs
terraform output vm_public_ip     # Just the VM IP
terraform output ssh_connection_string  # Ready-to-use SSH command
```

| Output | Description |
|--------|-------------|
| `vm_public_ip` | Public IP of the VM |
| `vm_private_ip` | Private IP of the VM |
| `ssh_connection_string` | Full SSH command |
| `storage_account_name` | Storage account name |
| `backup_vault_name` | Backup vault name |
| `migration_summary` | Full summary object |

---

## Dynamic NSG (dynamic_nsg.tf)

If you ran `discover_fyre_network.sh` first, copy the discovered NSG rules into the Terraform folder:

```bash
# Copy discovered NSG rules into terraform folder
cp ../fyre_discovery_*/azure_nsg_rules.json azure_terraform/discovered_nsg_rules.json
```

`dynamic_nsg.tf` will read that file and create NSG rules for every port your VM was actually using — instead of only the hardcoded SSH/TWS/DB2 ports in `main.tf`.

---

## Teardown

```bash
# Destroy everything created by Terraform
terraform destroy
```

---

*Made with Bob*
