# 🛠️ Azure Migrate Setup Guide (Approach 2)

Complete step-by-step guide to set up Azure Migrate for Fyre-to-Azure migrations.

---

## 📋 Table of Contents

1. [Prerequisites](#prerequisites)
2. [Phase 1: Create Azure Migrate Project](#phase-1-create-azure-migrate-project)
3. [Phase 2: Deploy Migration Appliance](#phase-2-deploy-migration-appliance)
4. [Phase 3: Configure Discovery](#phase-3-configure-discovery)
5. [Phase 4: Verify Setup](#phase-4-verify-setup)
6. [Troubleshooting](#troubleshooting)

---

## Prerequisites

### What You Need:

✅ **Azure Subscription**
- Active Azure subscription
- Contributor or Owner role
- Enough quota for VMs

✅ **Fyre VM Access**
- SSH access to Fyre VMs
- Root or sudo privileges
- Network connectivity

✅ **Network Requirements**
- Fyre VMs can reach Azure (outbound HTTPS)
- Azure can reach Fyre VMs (for replication)
- VPN or ExpressRoute (recommended)

✅ **Tools Installed**
- Azure CLI (`az`)
- SSH client
- Web browser (for Azure Portal)

### Check Prerequisites:

```bash
# 1. Check Azure CLI
az --version
# Should show: azure-cli 2.x.x or higher

# 2. Check Azure login
az account show
# Should show your subscription

# 3. Check SSH to Fyre
ssh root@<fyre-vm-ip> "echo 'Connected'"
# Should show: Connected

# 4. Check network connectivity
ping portal.azure.com
# Should get responses
```

---

## Phase 1: Create Azure Migrate Project

### Step 1.1: Login to Azure Portal

```bash
# Open browser
https://portal.azure.com

# Or use CLI
az login
```

### Step 1.2: Navigate to Azure Migrate

**In Azure Portal:**
1. Search for "Azure Migrate" in top search bar
2. Click "Azure Migrate"
3. Click "Get started"

**Or use direct link:**
```
https://portal.azure.com/#blade/Microsoft_Azure_Migrate/AmhResourceMenuBlade/overview
```

### Step 1.3: Create Migration Project

**In Portal:**
1. Click "Create project"
2. Fill in details:
   ```
   Subscription: [Your subscription]
   Resource Group: [Create new] "rg-azure-migrate"
   Project Name: "fyre-to-azure-migration"
   Geography: "United States" (or your region)
   ```
3. Click "Create"
4. Wait 2-3 minutes for project creation

**Using CLI:**
```bash
# Create resource group
az group create \
  --name rg-azure-migrate \
  --location eastus

# Create Azure Migrate project
az migrate project create \
  --name fyre-to-azure-migration \
  --resource-group rg-azure-migrate \
  --location eastus
```

### Step 1.4: Verify Project Created

```bash
# Check project
az migrate project show \
  --name fyre-to-azure-migration \
  --resource-group rg-azure-migrate

# Should show project details
```

---

## Phase 2: Deploy Migration Appliance

### What is the Appliance?

The **Azure Migrate Appliance** is a lightweight VM that:
- Discovers your Fyre VMs
- Collects performance data
- Sends data to Azure Migrate
- Manages replication

### Step 2.1: Choose Deployment Method

**Option A: Deploy on Azure (Recommended)**
- Easier setup
- Better connectivity
- Lower latency

**Option B: Deploy on-premises**
- If you have VMware/Hyper-V
- More complex setup

**We'll use Option A (Azure VM)**

### Step 2.2: Deploy Appliance VM

**In Azure Portal:**

1. Go to your Azure Migrate project
2. Click "Servers, databases and web apps"
3. Click "Discover" under "Migration tools"
4. Select "Yes, with Hyper-V" (or your hypervisor)
5. Click "Download" to get appliance VHD
6. Follow wizard to deploy

**Using CLI (Faster):**

```bash
# Create appliance VM
az vm create \
  --resource-group rg-azure-migrate \
  --name azure-migrate-appliance \
  --image MicrosoftWindowsServer:WindowsServer:2019-Datacenter:latest \
  --size Standard_D4s_v3 \
  --admin-username azureadmin \
  --admin-password 'YourSecurePassword123!' \
  --public-ip-address-allocation static \
  --nsg-rule RDP

# Get public IP
az vm show \
  --resource-group rg-azure-migrate \
  --name azure-migrate-appliance \
  --show-details \
  --query publicIps -o tsv

# Note the IP: e.g., 20.10.20.30
```

### Step 2.3: Configure Appliance

**Connect to Appliance:**

1. RDP to appliance IP (Windows)
   ```
   mstsc /v:20.10.20.30
   ```

2. Or SSH (if Linux appliance)
   ```bash
   ssh azureadmin@20.10.20.30
   ```

**Run Configuration:**

1. Open browser on appliance
2. Navigate to: `https://localhost:44368`
3. Accept certificate warning
4. Follow setup wizard:
   - Accept license terms
   - Set up prerequisites
   - Register with Azure Migrate
   - Provide Azure credentials

**Register Appliance:**

```powershell
# On appliance, run:
cd "C:\Program Files\Microsoft Azure Appliance Configuration Manager"
.\AzureMigrateInstaller.ps1

# Follow prompts:
# - Azure subscription ID
# - Azure Migrate project name
# - Resource group name
```

### Step 2.4: Verify Appliance Registration

**In Azure Portal:**
1. Go to Azure Migrate project
2. Click "Servers, databases and web apps"
3. Check "Discovered servers"
4. Should show: "Appliance registered"

**Using CLI:**
```bash
# Check appliance status
az migrate appliance show \
  --resource-group rg-azure-migrate \
  --project-name fyre-to-azure-migration

# Should show: "status": "Registered"
```

---

## Phase 3: Configure Discovery

### Step 3.1: Add Fyre VM Credentials

**In Azure Portal:**

1. Go to Azure Migrate project
2. Click "Servers, databases and web apps"
3. Click "Manage" → "Credentials"
4. Click "Add credentials"
5. Fill in:
   ```
   Friendly name: fyre-root-access
   Username: root
   Password: [your Fyre VM password]
   ```
6. Click "Save"

**Or use SSH key:**
```
Friendly name: fyre-ssh-key
Username: root
Authentication type: SSH key
Private key: [paste your private key]
```

### Step 3.2: Start Discovery

**In Azure Portal:**

1. Go to appliance configuration page
2. Click "Start discovery"
3. Enter Fyre VM details:
   ```
   IP address or FQDN: 9.46.186.146
   Credentials: fyre-root-access
   ```
4. Click "Add"
5. Repeat for each Fyre VM
6. Click "Start discovery"

**Using CLI:**
```bash
# Add Fyre VM for discovery
az migrate machine create \
  --resource-group rg-azure-migrate \
  --project-name fyre-to-azure-migration \
  --machine-name fyre-vm-1 \
  --ip-address 9.46.186.146 \
  --credentials fyre-root-access
```

### Step 3.3: Wait for Discovery

**Timeline:**
- Initial discovery: 15-30 minutes
- Performance data collection: 24 hours (recommended)

**Monitor Progress:**

```bash
# Check discovery status
az migrate machine list \
  --resource-group rg-azure-migrate \
  --project-name fyre-to-azure-migration \
  --query "[].{Name:name, Status:discoveryStatus}" \
  --output table

# Should show:
# Name        Status
# ----------  -----------
# fyre-vm-1   Discovered
```

**In Portal:**
1. Go to Azure Migrate project
2. Click "Servers, databases and web apps"
3. Check "Discovered servers" count
4. Should increase as discovery progresses

---

## Phase 4: Verify Setup

### Step 4.1: Check Discovered VMs

**In Portal:**
1. Go to Azure Migrate → Servers
2. Click "Discovered servers"
3. Should see your Fyre VMs listed

**Using CLI:**
```bash
# List discovered VMs
az migrate machine list \
  --resource-group rg-azure-migrate \
  --project-name fyre-to-azure-migration \
  --output table

# Should show:
# Name        OS      CPU  RAM    Disk
# ----------  ------  ---  -----  ------
# fyre-vm-1   Linux   8    14GB   500GB
```

### Step 4.2: Review Assessment

**In Portal:**
1. Click "Assess" → "Servers"
2. Create new assessment
3. Review:
   - Azure readiness
   - Recommended VM sizes
   - Cost estimates
   - Compatibility issues

**Using CLI:**
```bash
# Create assessment
az migrate assessment create \
  --resource-group rg-azure-migrate \
  --project-name fyre-to-azure-migration \
  --assessment-name fyre-assessment \
  --machines fyre-vm-1

# View assessment
az migrate assessment show \
  --resource-group rg-azure-migrate \
  --project-name fyre-to-azure-migration \
  --assessment-name fyre-assessment
```

### Step 4.3: Verify Network Connectivity

**Test from Appliance to Fyre:**
```bash
# On appliance
ping 9.46.186.146
# Should get responses

# Test SSH
ssh root@9.46.186.146 "echo 'Connected'"
# Should show: Connected
```

**Test from Fyre to Azure:**
```bash
# On Fyre VM
curl -I https://management.azure.com
# Should get HTTP 200 or 401 (means connectivity works)

# Test Azure Storage
curl -I https://[storageaccount].blob.core.windows.net
# Should get response
```

### Step 4.4: Check Prerequisites

**Run prerequisite checker:**
```bash
# On Fyre VM
curl -o check_prereqs.sh https://aka.ms/migrate-prereqs
chmod +x check_prereqs.sh
./check_prereqs.sh

# Should show:
# ✓ OS supported
# ✓ Disk space available
# ✓ Network connectivity
# ✓ Required ports open
```

---

## Troubleshooting

### Issue 1: Appliance Not Registering

**Symptoms:**
- Appliance shows "Not registered"
- Can't connect to Azure

**Solutions:**

```bash
# 1. Check internet connectivity
ping portal.azure.com

# 2. Check Azure credentials
az account show

# 3. Re-register appliance
cd "C:\Program Files\Microsoft Azure Appliance Configuration Manager"
.\AzureMigrateInstaller.ps1 -Reregister

# 4. Check firewall rules
# Ensure outbound HTTPS (443) is allowed
```

### Issue 2: Discovery Not Finding VMs

**Symptoms:**
- No VMs discovered after 30 minutes
- Discovery status stuck

**Solutions:**

```bash
# 1. Verify credentials
ssh root@9.46.186.146
# Should connect without password prompt

# 2. Check network connectivity
# From appliance:
ping 9.46.186.146
telnet 9.46.186.146 22

# 3. Check Fyre VM firewall
# On Fyre VM:
iptables -L -n | grep 22
# Should show ACCEPT for port 22

# 4. Restart discovery
# In portal: Stop discovery → Start discovery
```

### Issue 3: Performance Data Not Collected

**Symptoms:**
- VMs discovered but no performance data
- Assessment shows "Insufficient data"

**Solutions:**

```bash
# 1. Wait longer (needs 24 hours for accurate data)

# 2. Check appliance services
# On appliance:
Get-Service | Where-Object {$_.Name -like "*Azure*"}
# All should be "Running"

# 3. Check appliance logs
# On appliance:
cd "C:\ProgramData\Microsoft Azure\Logs"
Get-Content .\AzureMigrateAppliance.log -Tail 50

# 4. Restart appliance services
Restart-Service -Name "Azure Migrate*"
```

### Issue 4: Network Connectivity Issues

**Symptoms:**
- Can't reach Fyre VMs from appliance
- Replication fails

**Solutions:**

```bash
# 1. Check VPN/ExpressRoute
# Ensure connection is active

# 2. Check NSG rules
az network nsg rule list \
  --resource-group rg-azure-migrate \
  --nsg-name appliance-nsg \
  --output table

# 3. Add required rules
az network nsg rule create \
  --resource-group rg-azure-migrate \
  --nsg-name appliance-nsg \
  --name allow-fyre-ssh \
  --priority 1000 \
  --source-address-prefixes 9.46.186.0/24 \
  --destination-port-ranges 22 \
  --access Allow \
  --protocol Tcp

# 4. Test connectivity
# From appliance:
Test-NetConnection -ComputerName 9.46.186.146 -Port 22
```

---

## Next Steps

After setup is complete:

1. **Wait for Discovery** (15-30 minutes)
   - Check "Discovered servers" count
   - Verify all VMs found

2. **Review Assessment** (after 24 hours for best data)
   - Check Azure readiness
   - Review cost estimates
   - Confirm VM sizes

3. **Start Replication** (see MIGRATION_GUIDE.md)
   - Install mobility service
   - Begin data replication
   - Monitor progress

4. **Test Migration** (optional but recommended)
   - Create test VM
   - Verify functionality
   - Clean up test

5. **Final Migration** (when ready)
   - Stop source VM
   - Final sync
   - Start Azure VM

---

## Useful Commands Reference

```bash
# Check project status
az migrate project show \
  --name fyre-to-azure-migration \
  --resource-group rg-azure-migrate

# List discovered machines
az migrate machine list \
  --resource-group rg-azure-migrate \
  --project-name fyre-to-azure-migration

# Check appliance status
az migrate appliance show \
  --resource-group rg-azure-migrate \
  --project-name fyre-to-azure-migration

# View assessment
az migrate assessment show \
  --resource-group rg-azure-migrate \
  --project-name fyre-to-azure-migration \
  --assessment-name fyre-assessment

# Check replication status
az migrate replication list \
  --resource-group rg-azure-migrate \
  --project-name fyre-to-azure-migration
```

---

## Cost Estimate

**Setup Costs:**
- Azure Migrate Project: Free
- Appliance VM (Standard_D4s_v3): ~$140/month
- Storage for replication: ~$50-100/month
- Network egress: ~$10-50/month

**Total Setup Cost:** ~$200-300/month while migrating

**Note:** Delete appliance after migration to stop costs!

---

## Summary

✅ **What We Set Up:**
1. Azure Migrate project
2. Migration appliance
3. Discovery configuration
4. Network connectivity

✅ **What's Next:**
- Wait for discovery to complete
- Review assessment
- Start replication (see MIGRATION_GUIDE.md)

✅ **Time Required:**
- Setup: 30-60 minutes
- Discovery: 15-30 minutes
- Performance data: 24 hours (optional)

---

**Ready to migrate? See MIGRATION_GUIDE.md for next steps!**