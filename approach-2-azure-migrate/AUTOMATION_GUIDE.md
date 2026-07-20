# 🤖 Azure Migrate Automation Guide

Complete guide to using the automated scripts for Azure Migrate migrations.

---

## 📋 Overview

We've created four powerful automation scripts that bring the same ease-of-use from Approach 1 (custom scripts) to Approach 2 (Azure Migrate). These scripts automate discovery, setup, validation, and provide interactive guidance through the migration process.

---

## 🎯 Quick Start

### Complete Migration in 3 Commands

```bash
cd approach-2-azure-migrate

# 1. Check prerequisites (2 minutes)
./check_migrate_prerequisites.sh my-fyre-vm.fyre.ibm.com

# 2. Run complete migration (2-4 hours, interactive)
./azure_migrate_complete.sh my-fyre-vm.fyre.ibm.com eastus

# 3. Validate migration (2 minutes)
./validate_migration.sh my-migrated-vm rg-azure-migrate
```

**That's it!** The scripts guide you through everything.

---

## 📚 Script Reference

### 1. check_migrate_prerequisites.sh

**Purpose:** Comprehensive prerequisites checker

**Usage:**
```bash
./check_migrate_prerequisites.sh [fyre-vm-hostname]
```

**What it checks:**
- ✅ Local tools (Azure CLI, SSH, jq, curl)
- ✅ Azure authentication and subscription access
- ✅ Azure quotas and allowed regions
- ✅ Network connectivity (Azure and Fyre)
- ✅ Fyre VM requirements (OS, disk, memory, sudo)
- ✅ Azure Migrate provider availability
- ✅ Cost estimates

**Example output:**
```
Prerequisites Check Summary
Results:
  Passed: 15
  Warnings: 2
  Failed: 0

✓ All prerequisites met! Ready to migrate.

Next steps:
  1. Run: ./azure_migrate_discover.sh my-fyre-vm.fyre.ibm.com
  2. Or: ./azure_migrate_complete.sh my-fyre-vm.fyre.ibm.com
```

**When to use:**
- Before starting any migration
- To verify your environment is ready
- To troubleshoot setup issues

---

### 2. azure_migrate_discover.sh

**Purpose:** Automatic VM discovery and project setup

**Usage:**
```bash
./azure_migrate_discover.sh <fyre-vm-hostname>
```

**What it does:**
1. Tests SSH connection to Fyre VM
2. Discovers VM configuration:
   - Hostname and IP address
   - OS type and version
   - CPU count and memory
   - Disk configuration
   - Network interfaces
   - Listening ports (TCP/UDP)
3. Creates Azure Migrate project
4. Creates resource group
5. Generates recommended Azure VM size
6. Creates migration configuration files
7. Generates detailed next steps guide

**Output files:**
```
azure_migrate_discovery_TIMESTAMP/
├── vm_discovery.json          # Complete VM details
├── migration_config.json      # Azure recommendations
├── migrate_project.json       # Project details
├── NEXT_STEPS.md             # What to do next
└── discovery.log             # Detailed log
```

**Example:**
```bash
./azure_migrate_discover.sh itz-693000iler-gw3v1m6w.dev.fyre.ibm.com

# Output:
✓ VM discovered: itz-693000iler-gw3v1m6w
✓ Azure Migrate project created: fyre-to-azure-migrate
✓ Configuration generated

VM Summary:
  Hostname: itz-693000iler-gw3v1m6w
  IP Address: 9.46.186.146
  OS: Red Hat Enterprise Linux 9.6
  CPU: 8 cores
  Memory: 14GB
  TCP Ports: 12 listening
  UDP Ports: 3 listening

Recommended Azure Configuration:
  VM Size: Standard_D8s_v3
  OS Disk: 250GB
  Location: eastus
```

**When to use:**
- First step in migration process
- To understand your Fyre VM configuration
- To get Azure recommendations
- Before manual migration steps

---

### 3. azure_migrate_complete.sh

**Purpose:** Interactive complete migration workflow

**Usage:**
```bash
./azure_migrate_complete.sh <fyre-vm-hostname> [azure-location]
```

**Migration phases:**

#### Phase 1: Prerequisites and Discovery
- Verifies all requirements
- Discovers Fyre VM configuration
- Tests connectivity

#### Phase 2: Setup Azure Migrate Project
- Creates resource group
- Creates Azure Migrate project
- Saves project details

#### Phase 3: Deploy Migration Appliance
- Deploys Windows Server VM for appliance
- Configures networking
- Provides RDP access details
- **Interactive:** Asks for confirmation before deployment

#### Phase 4: Configure Discovery
- Provides step-by-step instructions
- Shows appliance configuration URL
- Guides through credential setup
- **Interactive:** Waits for user to complete setup

#### Phase 5: Start Replication
- Provides replication setup instructions
- Shows Azure Portal steps
- Guides through configuration
- **Interactive:** Waits for replication to start

#### Phase 6: Test Migration (Optional)
- Offers optional test migration
- Provides test instructions
- Guides through validation
- **Interactive:** User chooses to test or skip

#### Phase 7: Final Migration
- Confirms production cutover
- Provides migration steps
- Guides through final sync
- **Interactive:** Requires confirmation

#### Phase 8: Post-Migration Verification
- Provides verification checklist
- Shows useful commands
- Guides through testing
- **Interactive:** Waits for verification

#### Phase 9: Cleanup
- Offers to delete appliance (save costs)
- Offers to delete project
- Keeps migrated VM
- **Interactive:** User chooses what to delete

**Features:**
- 🎨 Beautiful colored output
- 📝 Detailed logging to file
- ⏸️ Interactive confirmations
- 📊 Progress tracking
- 📄 Automatic report generation
- ⚠️ Safety confirmations before critical actions

**Example session:**
```bash
./azure_migrate_complete.sh my-fyre-vm.fyre.ibm.com eastus

╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║      Azure Migrate - Complete Migration Automation           ║
║                                                               ║
║              Fyre VM → Azure (Official Tool)                  ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝

Phase 1: Prerequisites and Discovery
────────────────────────────────────────────────────────────────
✓ All required tools installed
✓ Azure authenticated: My Subscription
✓ SSH connection successful
✓ VM discovered: my-fyre-vm (9.46.186.146)

Phase 2: Setup Azure Migrate Project
────────────────────────────────────────────────────────────────
✓ Resource group created
✓ Azure Migrate project ready

Phase 3: Deploy Migration Appliance
────────────────────────────────────────────────────────────────
⚠ Deploy Azure Migrate appliance VM? (~$140/month while active)
Continue? (yes/no): yes

▶ Creating appliance VM (this takes 5-10 minutes)...
✓ Appliance deployed: 20.10.20.30

Appliance Details:
  IP: 20.10.20.30
  Username: azureadmin
  Password: AzureMigrate@2026!
  RDP: mstsc /v:20.10.20.30

[... continues through all phases ...]

Migration Complete! 🎉
────────────────────────────────────────────────────────────────
✓ Fyre VM migrated to Azure
✓ All resources configured
✓ Migration report generated

Output Directory: azure_migrate_20260709_153000
```

**When to use:**
- For complete end-to-end migration
- When you want guided interactive process
- For production migrations
- When you need detailed logging

---

### 4. validate_migration.sh

**Purpose:** Comprehensive post-migration validation

**Usage:**
```bash
./validate_migration.sh <azure-vm-name> [resource-group]
```

**What it validates:**

#### VM Status
- ✅ VM exists in Azure
- ✅ VM is running
- ✅ VM size and location
- ✅ OS type

#### Network Configuration
- ✅ Public IP assigned
- ✅ Private IP assigned
- ✅ Network interface configured
- ✅ SSH port accessible

#### Storage Configuration
- ✅ OS disk attached
- ✅ Data disks attached
- ✅ Disk sizes and types

#### SSH Connectivity
- ✅ Can connect via SSH
- ✅ Remote hostname
- ✅ System uptime

#### Performance Metrics
- ✅ CPU count
- ✅ Memory usage
- ✅ Disk usage
- ✅ Load average

#### Backup Configuration
- ✅ Azure Backup status
- ✅ Protection policy

#### Security
- ✅ Password authentication disabled
- ✅ Boot diagnostics enabled
- ✅ NSG attached

#### Cost Information
- ✅ Estimated monthly costs
- ✅ Cost-saving tips

**Example output:**
```bash
./validate_migration.sh my-migrated-vm rg-azure-migrate

Azure Migrate - Migration Validator
════════════════════════════════════════════════════════════════

Validating VM: my-migrated-vm
Resource Group: rg-azure-migrate

VM Status
────────────────────────────────────────────────────────────────
✓ VM exists: my-migrated-vm
✓ VM is running
ℹ VM Size: Standard_D4s_v3
ℹ Location: eastus
ℹ OS Type: Linux

Network Configuration
────────────────────────────────────────────────────────────────
✓ Public IP assigned: 20.30.40.50
  SSH: ssh azureuser@20.30.40.50
✓ Private IP assigned: 10.0.1.4
✓ Network interface configured
✓ SSH port (22) is accessible

Storage Configuration
────────────────────────────────────────────────────────────────
✓ OS Disk: my-migrated-vm-os-disk (250GB, Premium_LRS)
✓ Data disks attached: 1
  - my-migrated-vm-data-disk (500GB, Premium_LRS)

SSH Connectivity
────────────────────────────────────────────────────────────────
✓ SSH connection successful (key-based)
ℹ Remote hostname: my-migrated-vm
ℹ Uptime: up 2 hours, 15 minutes

Performance Metrics
────────────────────────────────────────────────────────────────
ℹ CPU Cores: 4
ℹ Memory: 2.1G / 15G used
ℹ Root disk usage: 35%
ℹ Load average: 0.15, 0.10, 0.08

Backup Configuration
────────────────────────────────────────────────────────────────
⚠ Azure Backup not configured (recommended for production)
  Enable in Azure Portal or with: az backup protection enable-for-vm

Security Configuration
────────────────────────────────────────────────────────────────
✓ Password authentication disabled (SSH keys only)
✓ Boot diagnostics enabled
✓ Network Security Group attached

Validation Summary
════════════════════════════════════════════════════════════════
Results:
  Passed: 18
  Warnings: 2
  Failed: 0

✓ Migration validated successfully!

Your VM is ready for production use.

Next steps:
  1. Test your application on the Azure VM
  2. Update DNS to point to Azure IP
  3. Monitor performance in Azure Portal
  4. Configure backup if not already enabled
  5. Delete source Fyre VM when confident
```

**When to use:**
- After migration completes
- To verify everything works
- Before deleting source VM
- For troubleshooting issues
- For documentation/audit

---

## 🎯 Usage Scenarios

### Scenario 1: First-Time Migration

```bash
# Step 1: Check if ready
./check_migrate_prerequisites.sh my-fyre-vm.fyre.ibm.com

# Step 2: Discover VM
./azure_migrate_discover.sh my-fyre-vm.fyre.ibm.com

# Step 3: Review recommendations
cat azure_migrate_discovery_*/migration_config.json

# Step 4: Run complete migration
./azure_migrate_complete.sh my-fyre-vm.fyre.ibm.com

# Step 5: Validate
./validate_migration.sh my-fyre-vm
```

### Scenario 2: Quick Check Only

```bash
# Just check prerequisites
./check_migrate_prerequisites.sh my-fyre-vm.fyre.ibm.com

# Review output and fix any issues
```

### Scenario 3: Discovery Only

```bash
# Discover VM and get recommendations
./azure_migrate_discover.sh my-fyre-vm.fyre.ibm.com

# Review generated files
cat azure_migrate_discovery_*/NEXT_STEPS.md
cat azure_migrate_discovery_*/migration_config.json

# Then follow manual steps or use complete script
```

### Scenario 4: Validation Only

```bash
# After manual migration
./validate_migration.sh my-migrated-vm rg-azure-migrate

# Review validation results
```

---

## 🔧 Troubleshooting

### Script Won't Run

**Problem:** Permission denied

**Solution:**
```bash
chmod +x *.sh
```

### Azure CLI Not Logged In

**Problem:** "Not logged into Azure CLI"

**Solution:**
```bash
az login
az account set --subscription "Your-Subscription-Name"
```

### SSH Connection Fails

**Problem:** Cannot connect to Fyre VM

**Solution:**
```bash
# Setup SSH keys
ssh-keygen -t rsa -b 4096
ssh-copy-id root@fyre-vm-hostname

# Test connection
ssh root@fyre-vm-hostname "echo 'Connected'"
```

### Quota Exceeded

**Problem:** "exceeding approved quota"

**Solution:**
- Use smaller VM size in script
- Request quota increase in Azure Portal
- Try different Azure region

### Script Hangs

**Problem:** Script appears stuck

**Solution:**
- Check network connectivity
- Verify SSH connection works
- Check Azure Portal for errors
- Review log files in output directory

---

## 📊 Comparison with Approach 1

| Feature | Approach 1 Scripts | Approach 2 Scripts |
|---------|-------------------|-------------------|
| **Discovery** | ✅ Automatic | ✅ Automatic |
| **Prerequisites Check** | ✅ Yes | ✅ Yes |
| **Project Setup** | Terraform | Azure Migrate |
| **Data Transfer** | Manual | Automatic |
| **Downtime** | Full migration | <5 minutes |
| **Interactive Guidance** | ❌ No | ✅ Yes |
| **Validation** | ✅ Yes | ✅ Yes |
| **Time to Complete** | 30 min | 2-4 hours |
| **Best For** | Quick migrations | Production migrations |

---

## 💡 Tips and Best Practices

### Before Migration

1. **Always run prerequisites check first**
   ```bash
   ./check_migrate_prerequisites.sh <fyre-vm>
   ```

2. **Review discovery results carefully**
   ```bash
   cat azure_migrate_discovery_*/migration_config.json
   ```

3. **Backup important data**
   - Use Fyre VM backup tools
   - Or manually copy critical files

### During Migration

1. **Don't skip test migration**
   - Validates everything works
   - No impact on production
   - Easy to clean up

2. **Monitor progress in Azure Portal**
   - Check replication status
   - Watch for errors
   - Verify data sync

3. **Keep logs for troubleshooting**
   - All scripts create log files
   - Save output directories
   - Document any issues

### After Migration

1. **Always validate**
   ```bash
   ./validate_migration.sh <vm-name>
   ```

2. **Test thoroughly before deleting source**
   - Verify all services work
   - Check data integrity
   - Test application functionality

3. **Clean up to save costs**
   - Delete appliance VM (~$140/month)
   - Delete Azure Migrate project
   - Stop VM when not in use

---

## 📝 Output Files

All scripts create organized output directories:

```
azure_migrate_discovery_TIMESTAMP/
├── vm_discovery.json          # VM details
├── migration_config.json      # Azure config
├── migrate_project.json       # Project info
├── NEXT_STEPS.md             # Instructions
└── discovery.log             # Detailed log

azure_migrate_TIMESTAMP/
├── vm_info.json              # Source VM info
├── project_info.json         # Project details
├── appliance_info.json       # Appliance credentials
├── MIGRATION_REPORT.md       # Final report
└── migration.log             # Complete log
```

---

## 🎓 Learning Resources

- **Azure Migrate Docs:** https://docs.microsoft.com/azure/migrate/
- **Azure CLI Reference:** https://docs.microsoft.com/cli/azure/
- **Troubleshooting Guide:** ../TROUBLESHOOTING.md
- **Setup Guide:** SETUP_GUIDE.md
- **Comparison Guide:** COMPARISON.md

---

## 🤝 Support

### Getting Help

1. Check script output and logs
2. Review troubleshooting section above
3. Check Azure Portal for errors
4. Review Azure Migrate documentation

### Common Issues

See `../TROUBLESHOOTING_COMPLETE.md` for comprehensive troubleshooting guide.

---

## ✅ Summary

The automation scripts provide:

- ✅ **Easy to use** - Simple command-line interface
- ✅ **Comprehensive** - Cover entire migration workflow
- ✅ **Interactive** - Guide you through complex steps
- ✅ **Safe** - Confirmations before critical actions
- ✅ **Validated** - Thorough post-migration checks
- ✅ **Production-ready** - Tested and reliable

**Start your migration today:**
```bash
./check_migrate_prerequisites.sh <your-fyre-vm>
```

---

**Made with ❤️ for seamless Azure Migrate migrations**

*Last updated: 2026-07-09*