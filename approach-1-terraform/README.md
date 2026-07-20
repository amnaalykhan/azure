# Approach 1 — Custom Scripts + Terraform

Migrate a Fyre VM to Azure using shell scripts for discovery + backup/restore, and Terraform for infrastructure provisioning.

**Best for:** Dev/test environments, learning, quick migrations where full downtime is acceptable.

---

## How It Works

```
Step 1: discover_fyre_network.sh   SSH into Fyre VM → scan ports, firewall, disks
                                    Output: NSG rules JSON + Terraform vars
        ↓
Step 2: terraform apply             Create Azure infrastructure from Terraform templates
                                    Creates: VNet, NSG, VM, Disks, Storage, Backup Vault
        ↓
Step 3: migrate_any_fyre_vm.sh     Backup Fyre VM data → upload to Azure Storage
                                    → restore on Azure VM → validate
```

---

## Prerequisites

| Tool | Install |
|------|---------|
| Azure CLI | `brew install azure-cli` |
| Terraform >= 1.0 | `brew install terraform` |
| jq | `brew install jq` |
| SSH key access to Fyre VM | see below |

```bash
# Verify
az --version && terraform --version && jq --version

# Login to Azure
az login

# Get your IDs (needed for terraform.tfvars)
az account show --query "{subscription_id:id, tenant_id:tenantId}" -o table
```

---

## Step-by-Step Runbook

### Step 1 — Discover the Fyre VM

```bash
cd approach-1-terraform

./discover_fyre_network.sh <fyre-vm-hostname>

# Example
./discover_fyre_network.sh itz-693000iler-gw3v1m6w.dev.fyre.ibm.com
```

**What it does:**
- SSHs into the Fyre VM as root
- Scans all listening TCP/UDP ports
- Reads firewall rules (firewalld/iptables)
- Records network interfaces, routes, DNS
- Records VM resources (CPU, RAM, disk)

**Output:** `fyre_discovery_<timestamp>/` folder containing:
```
network_discovery.json      All discovered data
azure_nsg_rules.json        Azure NSG rules ready to apply
terraform_vars.auto.tfvars  Suggested Terraform variables
DISCOVERY_REPORT.md         Human-readable summary
```

---

### Step 2 — Configure Terraform

```bash
cd azure_terraform

# Copy the example config
cp terraform.tfvars.example terraform.tfvars

# Edit with your values
nano terraform.tfvars
```

**Minimum values to fill in:**

```hcl
subscription_id     = "YOUR_SUBSCRIPTION_ID"   # from az account show
tenant_id           = "YOUR_TENANT_ID"          # from az account show
ssh_public_key_path = "~/.ssh/id_ed25519.pub"  # your SSH public key path
allowed_ssh_cidr    = "YOUR_IP/32"              # your IP: curl ifconfig.me
```

**VM sizing** (based on Fyre VM — 8 vCPU, 14GB RAM):
```hcl
vm_size           = "Standard_D8s_v3"   # 8 vCPU, 32GB RAM
os_disk_size_gb   = 250
data_disk_size_gb = 500
```

---

### Step 3 — Deploy Azure Infrastructure

```bash
cd azure_terraform

# Initialise providers
terraform init

# Preview what will be created
terraform plan

# Deploy (takes ~5-10 minutes)
terraform apply
```

**Resources created:**
- Resource Group
- Virtual Network (10.0.0.0/16) + App Subnet + DB Subnet
- Network Security Group (rules from discovered ports)
- Linux VM (RHEL 9.6, size from tfvars)
- OS Disk (250GB Premium SSD)
- Data Disk (500GB Premium SSD)
- Storage Account + containers
- Recovery Services Vault + Backup Policy

**Note the outputs** — you'll need the VM IP:
```bash
terraform output vm_public_ip
terraform output ssh_connection_string
```

---

### Step 4 — Run the Migration

```bash
cd ..   # back to approach-1-terraform/

./migrate_any_fyre_vm.sh <fyre-vm-hostname>

# Example
./migrate_any_fyre_vm.sh itz-693000iler-gw3v1m6w.dev.fyre.ibm.com
```

**What it does:**
1. Backs up all data from Fyre VM (tarballs)
2. Uploads to Azure Blob Storage
3. SSHs into new Azure VM
4. Formats and mounts the data disk
5. Restores all data
6. Validates services

---

### Step 5 — Validate

```bash
# SSH into the Azure VM
ssh azureuser@$(cd azure_terraform && terraform output -raw vm_public_ip)

# Check services, data, disk
df -h
ls /opt/
systemctl list-units --type=service --state=running
```

---

## Script Reference

| Script | Where to run | Purpose |
|--------|-------------|---------|
| `discover_fyre_network.sh` | Your Mac | SSH into Fyre VM, collect network/disk/port inventory |
| `migrate_any_fyre_vm.sh` | Your Mac | Full end-to-end migration orchestrator (any VM) |
| `migrate_fyre_to_aure.sh` | Your Mac | TWS/DB2-specific migration (hardcoded paths) |
| `backup_fyre_vm.sh` | Fyre VM | Create local tarballs of TWS + DB2 + config |
| `restore_to_azure.sh` | Azure VM | Extract and restore tarballs on the Azure VM |
| `check_fyre_resources.sh` | Fyre VM | Pre-migration resource analysis report |
| `fix_azure_nsg.sh` | Your Mac | Fix or update NSG rules after deployment |

---

## Terraform Files Reference

| File | Purpose |
|------|---------|
| `main.tf` | All Azure resources: VNet, NSG, VM, disks, storage, backup |
| `variables.tf` | Variable definitions with descriptions and defaults |
| `outputs.tf` | Outputs: VM IP, SSH command, disk IDs, storage name |
| `dynamic_nsg.tf` | Reads `discovered_nsg_rules.json` → creates NSG rules dynamically |
| `terraform.tfvars` | Your configuration (subscription ID, VM size, SSH key) |
| `terraform.tfvars.example` | Template — copy this and fill in your values |

---

## Teardown

```bash
# Destroy all Azure resources created by Terraform
cd azure_terraform
terraform destroy
```

---

## Known Limitations

- Approach 1 creates a **fresh VM** from marketplace image — OS packages not migrated
- Backup paths are optimised for TWS/DB2 — other app data needs manual handling
- No incremental sync — full downtime required during data copy
- See [Approach 2](../approach-2-azure-migrate/README.md) for production-grade migration

---

*Made with Bob*
