# Fyre → Azure VM Migration

Migrate any IBM Fyre VM (or on-premise Linux VM) to Microsoft Azure — with full network configuration, all data, and all services intact.

Two approaches are provided. Pick based on your needs.

---

## Repository Structure

```
azure-migration/
│
├── README.md                        ← You are here
│
├── approach-1-terraform/            ← Approach 1: Custom Scripts + Terraform
│   ├── README.md                    ← Full runbook for Approach 1
│   ├── discover_fyre_network.sh     ← Step 1: Discover VM (ports, firewall, disks)
│   ├── migrate_any_fyre_vm.sh       ← Step 2: Full migration orchestrator
│   ├── migrate_fyre_to_aure.sh      ← Step 2 (alt): TWS/DB2-specific migration
│   ├── backup_fyre_vm.sh            ← Backup script (run on Fyre VM)
│   ├── restore_to_azure.sh          ← Restore script (run on Azure VM)
│   ├── check_fyre_resources.sh      ← Pre-migration resource check
│   ├── fix_azure_nsg.sh             ← Fix NSG rules post-deploy
│   └── azure_terraform/             ← Terraform infrastructure
│       ├── main.tf                  ← VNet, NSG, VM, Disks, Storage, Backup
│       ├── variables.tf             ← All configurable variables
│       ├── outputs.tf               ← VM IP, disk IDs, storage name
│       ├── dynamic_nsg.tf           ← NSG rules auto-built from discovery JSON
│       ├── terraform.tfvars         ← Your values (subscription ID, VM size etc.)
│       └── terraform.tfvars.example ← Template — copy this to terraform.tfvars
│
└── approach-2-azure-migrate/        ← Approach 2: Azure Migrate (recommended)
    ├── README.md                    ← Full runbook for Approach 2
    ├── migrate.sh                   ← Master orchestrator (runs all 5 phases)
    ├── 01_discover.sh               ← Phase 1: Deep VM inventory
    ├── 02_setup_azure_migrate.sh    ← Phase 2: Azure infrastructure
    ├── 03_replicate.sh              ← Phase 3: Backup + appliance + replication
    ├── 04_cutover.sh                ← Phase 4: Cutover (<5 min downtime)
    └── 05_validate.sh               ← Phase 5: Post-migration validation
```

---

## Which Approach?

| | Approach 1 — Terraform | Approach 2 — Azure Migrate |
|---|---|---|
| **Best for** | Dev/test, learning, quick wins | Production, any workload |
| **Downtime** | Full migration window (hours) | < 5 minutes |
| **Data transfer** | Manual tarballs via SCP | Automatic block-level replication |
| **VM result** | Fresh OS + data restored | Exact clone of source disk |
| **NSG rules** | Auto-built from discovered ports | Auto-built from discovered ports |
| **Setup time** | ~30 minutes | ~2–4 hours |
| **Rollback** | Manual | Safe — source untouched until you confirm |
| **Works for any app** | No (TWS/DB2 hardcoded) | Yes |

---

## Approach 1 — Quick Start

```bash
cd approach-1-terraform

# 1. Discover the Fyre VM (ports, firewall, network)
./discover_fyre_network.sh <fyre-vm-hostname>

# 2. Fill in your Azure credentials
cd azure_terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — add subscription_id, tenant_id, ssh_public_key_path

# 3. Deploy Azure infrastructure
terraform init
terraform plan
terraform apply

# 4. Run the migration
cd ..
./migrate_any_fyre_vm.sh <fyre-vm-hostname>
```

→ Full instructions: [`approach-1-terraform/README.md`](approach-1-terraform/README.md)

---

## Approach 2 — Quick Start

```bash
cd approach-2-azure-migrate

# Prerequisites (one-time)
az login
az provider register --namespace Microsoft.Migrate --wait
az provider register --namespace Microsoft.OffAzure --wait

# Run everything — interactive, with confirmation gates at each phase
./migrate.sh <fyre-vm-hostname> root eastus
```

Or run phases individually:

```bash
./01_discover.sh <fyre-vm-hostname> root
./02_setup_azure_migrate.sh <fyre-vm-hostname> root discovery_<timestamp>/ eastus
./03_replicate.sh <fyre-vm-hostname> root azure_setup_<timestamp>/created_resources.json
# [Wait for replication "Protected" status in Azure Portal — 1-2 hours]
./04_cutover.sh <fyre-vm-hostname> root backup_<timestamp>/phase3_state.json
./05_validate.sh <azure-vm-name> <resource-group> cutover_<timestamp>/phase4_state.json
```

→ Full instructions: [`approach-2-azure-migrate/README.md`](approach-2-azure-migrate/README.md)

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Azure CLI | any | `brew install azure-cli` |
| Terraform | >= 1.0 | `brew install terraform` (Approach 1 only) |
| jq | any | `brew install jq` |
| SSH client | any | built-in on macOS/Linux |

```bash
# Verify all tools
az --version && terraform --version && jq --version && ssh -V
```

---

## Azure Credentials Needed

```bash
# Login
az login

# Get your subscription and tenant IDs
az account show --query "{subscription_id:id, tenant_id:tenantId, name:name}" -o table
```

---

## Source VM Tested On

| Field | Value |
|-------|-------|
| Platform | IBM Fyre |
| Hostname | `itz-693000iler-gw3v1m6w.dev.fyre.ibm.com` |
| OS | Red Hat Enterprise Linux 9.6 |
| CPU | 8 vCPUs |
| RAM | 14 GB |
| Applications | IBM Workload Automation (TWS) + DB2 |

---

## Estimated Monthly Cost (Azure East US)

| Resource | Cost |
|----------|------|
| VM — Standard_D8s_v3 (8 vCPU, 32GB) | ~$280/month |
| OS Disk — 250GB Premium SSD | ~$38/month |
| Data Disk — 500GB Premium SSD | ~$75/month |
| Storage Account | ~$5/month |
| Azure Backup | ~$10/month |
| **Total** | **~$408/month** |

> Save 40–60% with Reserved Instances (1-year or 3-year commitment).

---

*Made with Bob*
