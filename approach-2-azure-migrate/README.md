# Approach 2 — Azure Migrate: Complete Migration Pipeline

Migrate any Fyre or on-premise Linux VM to Azure using Microsoft's Azure Migrate service — keeping the **exact OS**, all **installed packages**, all **data**, **network configuration**, and **services** intact.

**Best for:** Production workloads, any application, minimal downtime required.

---

## How It Works

```
Phase 1: 01_discover.sh         SSH into source VM → full inventory
                                  Output: 9 JSON files (OS, disks, ports, services, firewall)
         ↓
Phase 2: 02_setup_azure_migrate  Create Azure infra (VNet, NSG, Storage, Vault, Project)
                                  NSG rules auto-built from your actual listening ports
         ↓
Phase 3: 03_replicate.sh         Backup all data → Azure Storage
                                  Deploy appliance VM → register → start replication
                                  [Replication runs continuously in background — 1-2 hrs]
         ↓
Phase 4: 04_cutover.sh           Stop source VM → final sync → migrate
                                  Restore backups → configure networking
                                  Downtime: < 5 minutes
         ↓
Phase 5: 05_validate.sh          10-dimension validation: VM, network, disks,
                                  data, services, performance, security, backup, cost
```

---

## Prerequisites

| Tool | Install |
|------|---------|
| Azure CLI | `brew install azure-cli` |
| jq | `brew install jq` |
| SSH key access to source VM | passwordless (key-based) |

```bash
# Login to Azure
az login

# Register providers (one-time, takes ~2 min)
az provider register --namespace Microsoft.Migrate --wait
az provider register --namespace Microsoft.OffAzure --wait

# Verify
az provider show --namespace Microsoft.Migrate --query registrationState -o tsv
az provider show --namespace Microsoft.OffAzure --query registrationState -o tsv
# Both should print: Registered
```

---

## Quick Start — One Command

```bash
cd approach-2-azure-migrate

./migrate.sh <source-vm-hostname> <ssh-user> <azure-location>

# Example — Fyre VM
./migrate.sh itz-693000iler-gw3v1m6w.dev.fyre.ibm.com root eastus
```

The orchestrator runs all 5 phases with `yes / skip / abort` prompts between each phase. State is saved to `migration_state_<timestamp>.json` so you can resume if interrupted.

---

## Step-by-Step — Run Phases Individually

### Phase 1 — Discovery (~5 min)

```bash
./01_discover.sh <source-vm-hostname> <ssh-user>

# Example
./01_discover.sh itz-693000iler-gw3v1m6w.dev.fyre.ibm.com root
```

**Output:** `discovery_<timestamp>/` folder:

| File | Contents |
|------|----------|
| `vm_profile.json` | OS, CPU, RAM, hostname |
| `disks.json` | All block devices and mount points |
| `network.json` | Interfaces, IPs, routes, DNS |
| `listening_ports.json` | TCP/UDP ports + owning process |
| `firewall.json` | firewalld / iptables rules |
| `services.json` | Running and enabled services |
| `azure_sizing.json` | Recommended Azure VM size |
| `azure_nsg_rules.json` | Ready-to-apply NSG rules |
| `DISCOVERY_REPORT.md` | Human-readable summary |

```bash
# Check the report
cat discovery_*/DISCOVERY_REPORT.md

# Check recommended VM size
cat discovery_*/azure_sizing.json
```

---

### Phase 2 — Azure Infrastructure (~10 min)

```bash
./02_setup_azure_migrate.sh \
  <source-vm-hostname> \
  <ssh-user> \
  <discovery-dir> \
  <azure-location>

# Example
./02_setup_azure_migrate.sh \
  itz-693000iler-gw3v1m6w.dev.fyre.ibm.com \
  root \
  discovery_20250714_143022 \
  eastus
```

**Resources created in Azure:**
- Resource Group: `rg-<vmname>-migrate`
- VNet: `10.0.0.0/16` with app subnet + db subnet
- NSG: rules auto-generated from your discovered ports
- Storage Account + 3 containers (migration-files, backups, discovery)
- Recovery Services Vault
- Azure Migrate Project

**Output:** `azure_setup_<timestamp>/created_resources.json` — pass this to Phase 3.

---

### Phase 3 — Backup + Appliance (~20 min automated + 30 min manual)

```bash
./03_replicate.sh \
  <source-vm-hostname> \
  <ssh-user> \
  <resources-manifest>

# Example
./03_replicate.sh \
  itz-693000iler-gw3v1m6w.dev.fyre.ibm.com \
  root \
  azure_setup_20250714_150000/created_resources.json
```

**Automated:**
- Creates tarballs on source VM: `/etc`, `/home`, `/opt`, `/data`, systemd services, SSH keys
- Downloads to your Mac
- Uploads all backups to Azure Blob Storage
- Deploys Windows Server appliance VM in Azure

**Manual steps after script finishes** (the script prints exact instructions):

1. RDP into the appliance VM: `mstsc /v:<appliance-ip>`
2. Open browser → `https://localhost:44368`
3. Register with your Azure Migrate project
4. Add source VM credentials (IP, username, SSH key)
5. Click **Start discovery** → wait 15-30 min
6. In Azure Portal → Azure Migrate → **Replicate** → select your VM → click Replicate
7. Wait for status **"Protected"** (1-2 hours for initial sync)

---

### Phase 4 — Cutover (~15 min, <5 min downtime)

> Only run when replication status is **"Protected"** in Azure Portal.

```bash
./04_cutover.sh \
  <source-vm-hostname> \
  <ssh-user> \
  <phase3-state>

# Example
./04_cutover.sh \
  itz-693000iler-gw3v1m6w.dev.fyre.ibm.com \
  root \
  backup_20250714_160000/phase3_state.json
```

**What happens:**
1. Pre-cutover checklist
2. Gracefully stops source VM services
3. Prompts you to trigger final migration in Azure Portal (5-10 min)
4. Assigns static public IP to migrated VM
5. Formats and mounts data disk at `/data`
6. Restores all backups from Azure Storage
7. Reconfigures hostname, hosts file, firewall
8. Enables Azure Backup

**Output:** `cutover_<timestamp>/phase4_state.json` — pass to Phase 5.

---

### Phase 5 — Validate (~5 min)

```bash
./05_validate.sh \
  <azure-vm-name> \
  <resource-group> \
  <phase4-state>

# Example
./05_validate.sh \
  itz-693000iler-gw3v1m6w \
  rg-itz-693000iler-migrate \
  cutover_20250714_170000/phase4_state.json
```

**10 checks run automatically:**

| Check | What it verifies |
|-------|-----------------|
| VM Status | Power state, size, location, boot diagnostics |
| Network | Public IP, private IP, NSG, SSH port |
| Storage | OS disk, data disks, sizes, types |
| SSH & OS | Auth, hostname, kernel, uptime, /data mount |
| Data Integrity | Key directories, critical files present |
| Services | Running service count, sshd active |
| Performance | CPU, memory, load, disk available |
| Security | Password auth off, NSG attached, encryption |
| Backup | Azure Backup vault status |
| Cost | Monthly estimate + stop/start commands |

---

## After Migration

```bash
# SSH into the migrated VM
ssh azureuser@<public-ip>

# Update DNS — point your hostname to the new Azure IP
az vm show -g <resource-group> -n <vm-name> --show-details --query publicIps -o tsv

# Delete the appliance VM to save ~$140/month
az vm delete \
  --resource-group <resource-group> \
  --name azure-migrate-appliance \
  --yes

# Stop VM when not in use (saves cost)
az vm deallocate -g <resource-group> -n <vm-name>

# Start VM again
az vm start -g <resource-group> -n <vm-name>
```

---

## Azure Quota Note

Azure for Students gives **6 vCores**. Plan:
- Appliance VM: Standard_D4s_v3 = 4 cores
- Target VM: Standard_D2s_v3 = 2 cores
- Total: 6 cores (exactly fits)

When setting replication in Azure Portal, manually select **Standard_D2s_v3** as the target VM size. Request a quota increase if you need more.

---

## Estimated Cost

| Resource | Cost |
|----------|------|
| Appliance VM (temporary — delete after) | ~$140/month |
| Target VM Standard_D2s_v3 | ~$70/month |
| Target VM Standard_D8s_v3 | ~$280/month |
| Storage Account | ~$5/month |
| Azure Backup | ~$10/month |

---

*Made with Bob*
