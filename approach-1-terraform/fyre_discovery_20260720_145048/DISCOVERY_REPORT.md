# VM Discovery Report

**VM:** itz-693000iler-gw3v1m6w.dev.fyre.ibm.com (9.46.106.146)
**Date:** Mon Jul 20 14:53:11 IST 2026

---

## VM Profile

| Field | Value |
|-------|-------|
| Hostname | itz-693000iler-gw3v1m6w.dev.fyre.ibm.com |
| OS | Red Hat Enterprise Linux 9.6 (Plow) |
| CPU | 8 vCPUs |
| Memory | 15GB |
| IP | 10.23.149.166 |

## Listening TCP Ports

`22 `

## Azure Recommendation

| Resource | Value |
|----------|-------|
| VM Size | **Standard_D8s_v3** |
| OS Disk | 260GB SSD |
| Data Disk | 32GB SSD |

## Generated Files

| File | Purpose |
|------|---------|
| `vm_resources.json` | OS, CPU, memory |
| `listening_ports.json` | All listening ports |
| `network.json` | Interfaces, routes, DNS |
| `firewall.json` | Firewall rules |
| `services.json` | Running/enabled services |
| `azure_nsg_rules.json` | Ready-to-apply NSG rules |
| `terraform_vars.auto.tfvars` | Terraform variables |

## Next Steps

```bash
# 1. Fill in your subscription_id and tenant_id:
vi fyre_discovery_20260720_145048/terraform_vars.auto.tfvars

# 2. Copy to terraform directory and deploy:
cp fyre_discovery_20260720_145048/terraform_vars.auto.tfvars ../terraform/
cd ../terraform
terraform init && terraform plan && terraform apply
```
