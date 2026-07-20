# Auto-generated Terraform variables
# Source VM : 9.46.106.146
# Generated : Mon Jul 20 13:24:19 IST 2026

# ── Required — fill these in ───────────────────────────────────────────────────
subscription_id = "YOUR_SUBSCRIPTION_ID"
tenant_id       = "YOUR_TENANT_ID"

# ── Discovered VM config ───────────────────────────────────────────────────────
vm_size           = "Standard_D8s_v3"   # 8 vCPUs, 15GB RAM
os_disk_size_gb   = 260
data_disk_size_gb = 32
project_name      = "itz-693000iler-gw3v1"

# ── Location ──────────────────────────────────────────────────────────────────
location = "eastus2"

# ── Security ──────────────────────────────────────────────────────────────────
allowed_ssh_cidr = "0.0.0.0/0"   # Restrict to your IP for production
