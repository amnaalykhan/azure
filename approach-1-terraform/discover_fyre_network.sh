#!/bin/bash

################################################################################
# Fyre VM Network Discovery Script
#
# Discovers network config, ports, firewall rules, and VM specs from any
# Linux VM. Outputs structured JSON + Terraform variables.
#
# Usage:
#   ./discover_fyre_network.sh <user@host|host> [--password <pass>]
#
# Examples:
#   ./discover_fyre_network.sh root@9.46.106.146 --password MyP@ss123
#   ./discover_fyre_network.sh 9.46.106.146 --password MyP@ss123
#   ./discover_fyre_network.sh myvm.fyre.ibm.com              # key auth
################################################################################

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

header()  { echo -e "\n${CYAN}══════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════════════${NC}"; }
section() { echo -e "\n${BLUE}── $1 ──${NC}"; }
ok()      { echo -e "${GREEN}✓${NC} $1"; }
info()    { echo -e "${BLUE}ℹ${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
die()     { echo -e "${RED}✗ FATAL:${NC} $1"; exit 1; }

# ── Parse arguments ────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <user@host|host> [--password <pass>]"
    echo ""
    echo "Examples:"
    echo "  $0 root@9.46.106.146 --password MyP@ss123"
    echo "  $0 9.46.106.146 --password MyP@ss123"
    echo "  $0 myvm.fyre.ibm.com"
    exit 1
fi

# Split user@host or plain host
_ARG1="$1"
if [[ "$_ARG1" == *@* ]]; then
    SSH_USER="${_ARG1%%@*}"
    FYRE_VM="${_ARG1#*@}"
else
    FYRE_VM="$_ARG1"
    SSH_USER="root"
fi

# Parse --password
SSH_PASS=""
for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "--password" ]]; then
        j=$((i+1))
        SSH_PASS="${!j:-}"
        break
    fi
done

OUTPUT_DIR="fyre_discovery_$(date +%Y%m%d_%H%M%S)"
NSG_RULES_FILE="$OUTPUT_DIR/azure_nsg_rules.json"
TERRAFORM_VARS_FILE="$OUTPUT_DIR/terraform_vars.auto.tfvars"

# ── SSH helpers ────────────────────────────────────────────────────────────────
# ssh_run : run remote command, return its output+exit code as-is
ssh_run() {
    if [[ -n "$SSH_PASS" ]]; then
        sshpass -p "$SSH_PASS" ssh \
            -o ConnectTimeout=15 \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            "${SSH_USER}@${FYRE_VM}" "$@"
    else
        ssh \
            -o ConnectTimeout=15 \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=no \
            "${SSH_USER}@${FYRE_VM}" "$@"
    fi
}

# ssh_safe : run remote command, return stdout; empty string on failure
ssh_safe() { ssh_run "$@" 2>/dev/null || true; }

# ── Preflight ──────────────────────────────────────────────────────────────────
preflight() {
    # Check dependencies
    command -v jq     &>/dev/null || die "jq not installed.     Fix: brew install jq"
    if [[ -n "$SSH_PASS" ]]; then
        command -v sshpass &>/dev/null || die "sshpass not installed. Fix: brew install sshpass"
    fi

    mkdir -p "$OUTPUT_DIR"

    header "Fyre VM Network Discovery Tool"
    info "Target  : ${SSH_USER}@${FYRE_VM}"
    info "Output  : $OUTPUT_DIR"
    info "Auth    : $([ -n "$SSH_PASS" ] && echo 'password (sshpass)' || echo 'SSH key')"

    section "Testing SSH connection"
    local result
    result=$(ssh_run "echo connected" 2>&1) || true
    if [[ "$result" == *"connected"* ]]; then
        ok "SSH connection successful"
    else
        die "Cannot SSH to ${SSH_USER}@${FYRE_VM}
    Error    : $result
    Password : re-run with --password <your-password>
    Key auth : ensure ~/.ssh/id_rsa.pub is on the VM"
    fi
}

# ── Discovery ──────────────────────────────────────────────────────────────────
discover_vm_resources() {
    section "VM Resources"
    info "Collecting OS, CPU, memory..."

    local hostname os_pretty os_id kernel arch vcpus mem_gb disk_total disk_used
    hostname=$(ssh_safe "hostname")
    os_pretty=$(ssh_safe "grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'\"' -f2")
    os_id=$(ssh_safe "grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"'")
    kernel=$(ssh_safe "uname -r")
    arch=$(ssh_safe "uname -m")
    vcpus=$(ssh_safe "nproc")
    mem_gb=$(ssh_safe "awk '/MemTotal/ {printf \"%.0f\", \$2/1024/1024}' /proc/meminfo")
    disk_total=$(ssh_safe "df -BG --total 2>/dev/null | awk 'END {gsub(/G/,\"\",\$2); print \$2}'")
    disk_used=$(ssh_safe "df -BG --total 2>/dev/null | awk 'END {gsub(/G/,\"\",\$3); print \$3}'")

    cat > "$OUTPUT_DIR/vm_resources.json" <<EOF
{
  "hostname": "${hostname:-unknown}",
  "fqdn": "$FYRE_VM",
  "ssh_user": "$SSH_USER",
  "os": "${os_pretty:-unknown}",
  "os_id": "${os_id:-unknown}",
  "kernel": "${kernel:-unknown}",
  "architecture": "${arch:-unknown}",
  "vcpus": ${vcpus:-0},
  "memory_gb": ${mem_gb:-0},
  "disk_total_gb": ${disk_total:-0},
  "disk_used_gb": ${disk_used:-0},
  "discovered_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

    ok "VM resources saved"
    echo "  Hostname : ${hostname:-unknown}"
    echo "  OS       : ${os_pretty:-unknown}"
    echo "  CPU/Mem  : ${vcpus:-?} vCPUs | ${mem_gb:-?}GB RAM | ${disk_total:-?}GB disk"
}

discover_listening_ports() {
    section "Listening Ports"
    info "Scanning TCP and UDP listening ports..."

    local tcp_ports udp_ports
    tcp_ports=$(ssh_safe "ss -tlnp 2>/dev/null | awk 'NR>1 && /LISTEN/ {print \$4}' | sed 's/.*://' | sort -un")
    udp_ports=$(ssh_safe "ss -ulnp 2>/dev/null | awk 'NR>1 {print \$4}' | sed 's/.*://' | sort -un")

    local tcp_array="["
    while IFS= read -r port; do
        [[ -z "$port" || "$port" == "0" ]] && continue
        local proc
        proc=$(ssh_safe "ss -tlnp 2>/dev/null | awk '/:\b${port}\b/' | grep -oP 'users:\(\(\"\\K[^\"]+' | head -1")
        [[ -z "$proc" ]] && proc="unknown"
        tcp_array+="{\"port\":$port,\"protocol\":\"tcp\",\"process\":\"$proc\"},"
    done <<< "$tcp_ports"
    tcp_array="${tcp_array%,}]"

    local udp_array="["
    while IFS= read -r port; do
        [[ -z "$port" || "$port" == "0" ]] && continue
        udp_array+="{\"port\":$port,\"protocol\":\"udp\"},"
    done <<< "$udp_ports"
    udp_array="${udp_array%,}]"

    echo "{ \"tcp\": $tcp_array, \"udp\": $udp_array }" | jq . > "$OUTPUT_DIR/listening_ports.json"

    local tcp_count udp_count
    tcp_count=$(echo "$tcp_ports" | grep -c '[0-9]' || echo 0)
    udp_count=$(echo "$udp_ports" | grep -c '[0-9]' || echo 0)
    ok "Ports saved — TCP: $tcp_count | UDP: $udp_count"
    echo "  TCP ports: $(echo "$tcp_ports" | tr '\n' ' ')"
}

discover_network() {
    section "Network Configuration"

    local primary_ip gateway nameservers iface_json route_json hosts
    primary_ip=$(ssh_safe "hostname -I | awk '{print \$1}'")
    gateway=$(ssh_safe "ip route | awk '/default/ {print \$3; exit}'")
    nameservers=$(ssh_safe "awk '/^nameserver/ {print \$2}' /etc/resolv.conf | paste -sd,")
    iface_json=$(ssh_safe "ip -j addr show 2>/dev/null") || iface_json="[]"
    [[ -z "$iface_json" ]] && iface_json="[]"
    route_json=$(ssh_safe "ip -j route show 2>/dev/null") || route_json="[]"
    [[ -z "$route_json" ]] && route_json="[]"
    hosts=$(ssh_safe "cat /etc/hosts 2>/dev/null" | jq -R -s '.')

    cat > "$OUTPUT_DIR/network.json" <<EOF
{
  "primary_ip": "${primary_ip:-unknown}",
  "default_gateway": "${gateway:-unknown}",
  "nameservers": "${nameservers:-unknown}",
  "interfaces": $iface_json,
  "routes": $route_json,
  "hosts_file": $hosts
}
EOF

    ok "Network config saved"
    echo "  IP: ${primary_ip:-?} | Gateway: ${gateway:-?} | DNS: ${nameservers:-?}"
}

discover_firewall() {
    section "Firewall Rules"

    local fw_type="none"
    local fw_status
    fw_status=$(ssh_safe "systemctl is-active firewalld 2>/dev/null")

    if [[ "$fw_status" == "active" ]]; then
        fw_type="firewalld"
        local fw_all fw_ports fw_services
        fw_all=$(ssh_safe "firewall-cmd --list-all 2>/dev/null" | jq -R -s '.')
        fw_ports=$(ssh_safe "firewall-cmd --list-ports 2>/dev/null")
        fw_services=$(ssh_safe "firewall-cmd --list-services 2>/dev/null")
        echo "{\"type\":\"firewalld\",\"ports\":\"$fw_ports\",\"services\":\"$fw_services\",\"full_output\":$fw_all}" \
            | jq . > "$OUTPUT_DIR/firewall.json"
    else
        local ipt_lines
        ipt_lines=$(ssh_safe "iptables -L -n 2>/dev/null | wc -l")
        if [[ "${ipt_lines:-0}" -gt 3 ]]; then
            fw_type="iptables"
            local ipts
            ipts=$(ssh_safe "iptables-save 2>/dev/null" | jq -R -s '.')
            echo "{\"type\":\"iptables\",\"rules\":$ipts}" | jq . > "$OUTPUT_DIR/firewall.json"
        else
            echo '{"type":"none"}' > "$OUTPUT_DIR/firewall.json"
        fi
    fi

    ok "Firewall saved (type: $fw_type)"
}

discover_services() {
    section "System Services"

    local running enabled
    running=$(ssh_safe "systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print \$1}'" \
        | jq -R -s 'split("\n") | map(select(length>0))')
    enabled=$(ssh_safe "systemctl list-unit-files --type=service --state=enabled --no-legend 2>/dev/null | awk '{print \$1}'" \
        | jq -R -s 'split("\n") | map(select(length>0))')

    echo "{\"running\":${running:-[]},\"enabled\":${enabled:-[]}}" | jq . > "$OUTPUT_DIR/services.json"

    local count
    count=$(echo "${running:-[]}" | jq 'length' 2>/dev/null || echo 0)
    ok "Services saved ($count running)"
}

# ── Azure NSG Rule Generation ──────────────────────────────────────────────────
generate_azure_nsg_rules() {
    section "Generating Azure NSG Rules"

    local priority=100
    local nsg_array="["

    # SSH always first
    nsg_array+="{\"name\":\"SSH\",\"priority\":$priority,\"direction\":\"Inbound\",\"access\":\"Allow\",\"protocol\":\"Tcp\",\"source_port_range\":\"*\",\"destination_port_range\":\"22\",\"source_address_prefix\":\"*\",\"destination_address_prefix\":\"*\"},"
    priority=$((priority + 10))

    while IFS= read -r entry; do
        local port proc name
        port=$(echo "$entry" | jq -r '.port')
        proc=$(echo "$entry" | jq -r '.process')
        [[ "$port" == "22" || -z "$port" || "$port" == "null" ]] && continue
        name="Port-${port}"
        [[ "$proc" != "unknown" && "$proc" != "null" && -n "$proc" ]] && name="${proc}-${port}"
        name=$(echo "$name" | sed 's/[^a-zA-Z0-9-]/-/g' | cut -c1-80)
        nsg_array+="{\"name\":\"$name\",\"priority\":$priority,\"direction\":\"Inbound\",\"access\":\"Allow\",\"protocol\":\"Tcp\",\"source_port_range\":\"*\",\"destination_port_range\":\"$port\",\"source_address_prefix\":\"*\",\"destination_address_prefix\":\"*\"},"
        priority=$((priority + 10))
    done < <(jq -c '.tcp[]' "$OUTPUT_DIR/listening_ports.json" 2>/dev/null || true)

    # Outbound allow-all
    nsg_array+="{\"name\":\"AllowAllOutbound\",\"priority\":100,\"direction\":\"Outbound\",\"access\":\"Allow\",\"protocol\":\"*\",\"source_port_range\":\"*\",\"destination_port_range\":\"*\",\"source_address_prefix\":\"*\",\"destination_address_prefix\":\"*\"}"
    nsg_array+="]"

    echo "{\"nsg_rules\":$nsg_array}" | jq . > "$NSG_RULES_FILE"

    local rule_count
    rule_count=$(jq '.nsg_rules | length' "$NSG_RULES_FILE")
    ok "NSG rules saved ($rule_count rules)"
}

# ── Terraform Variables ────────────────────────────────────────────────────────
generate_terraform_vars() {
    section "Generating Terraform Variables"

    local vcpus mem_gb disk_total hostname
    vcpus=$(jq -r '.vcpus'        "$OUTPUT_DIR/vm_resources.json")
    mem_gb=$(jq -r '.memory_gb'   "$OUTPUT_DIR/vm_resources.json")
    disk_total=$(jq -r '.disk_total_gb' "$OUTPUT_DIR/vm_resources.json")
    hostname=$(jq -r '.hostname'  "$OUTPUT_DIR/vm_resources.json")

    local vm_size
    if   [[ ${vcpus:-0} -le 2 && ${mem_gb:-0} -le 8  ]]; then vm_size="Standard_D2s_v3"
    elif [[ ${vcpus:-0} -le 4 && ${mem_gb:-0} -le 16 ]]; then vm_size="Standard_D4s_v3"
    elif [[ ${vcpus:-0} -le 8 && ${mem_gb:-0} -le 32 ]]; then vm_size="Standard_D8s_v3"
    else vm_size="Standard_D16s_v3"; fi

    local os_disk_gb=$(( disk_total > 64 ? disk_total : 64 ))
    local data_disk_gb=32
    local safe_name
    safe_name=$(echo "$hostname" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]' | cut -c1-20)

    cat > "$TERRAFORM_VARS_FILE" <<EOF
# Auto-generated Terraform variables
# Source VM : $FYRE_VM
# Generated : $(date)

# ── Required — fill these in ───────────────────────────────────────────────────
subscription_id = "YOUR_SUBSCRIPTION_ID"
tenant_id       = "YOUR_TENANT_ID"

# ── Discovered VM config ───────────────────────────────────────────────────────
vm_size           = "$vm_size"   # ${vcpus} vCPUs, ${mem_gb}GB RAM
os_disk_size_gb   = $os_disk_gb
data_disk_size_gb = $data_disk_gb
project_name      = "$safe_name"

# ── Location ──────────────────────────────────────────────────────────────────
location = "eastus2"

# ── Security ──────────────────────────────────────────────────────────────────
allowed_ssh_cidr = "0.0.0.0/0"   # Restrict to your IP for production
EOF

    ok "Terraform vars saved: $TERRAFORM_VARS_FILE"
    echo "  Recommended VM size : $vm_size"
    echo "  OS disk             : ${os_disk_gb}GB"
}

# ── Summary Report ─────────────────────────────────────────────────────────────
generate_report() {
    section "Discovery Report"

    local vm_hostname vm_os vm_cpu vm_mem primary_ip tcp_ports vm_size os_disk_gb data_disk_gb
    vm_hostname=$(jq -r '.hostname'   "$OUTPUT_DIR/vm_resources.json")
    vm_os=$(jq -r '.os'               "$OUTPUT_DIR/vm_resources.json")
    vm_cpu=$(jq -r '.vcpus'           "$OUTPUT_DIR/vm_resources.json")
    vm_mem=$(jq -r '.memory_gb'       "$OUTPUT_DIR/vm_resources.json")
    primary_ip=$(jq -r '.primary_ip'  "$OUTPUT_DIR/network.json")
    tcp_ports=$(jq -r '.tcp[].port'   "$OUTPUT_DIR/listening_ports.json" 2>/dev/null | tr '\n' ' ')
    vm_size=$(grep 'vm_size' "$TERRAFORM_VARS_FILE" | cut -d'"' -f2)
    os_disk_gb=$(grep 'os_disk_size_gb' "$TERRAFORM_VARS_FILE" | awk '{print $3}')
    data_disk_gb=$(grep 'data_disk_size_gb' "$TERRAFORM_VARS_FILE" | awk '{print $3}')

    cat > "$OUTPUT_DIR/DISCOVERY_REPORT.md" <<EOF
# VM Discovery Report

**VM:** $vm_hostname ($FYRE_VM)
**Date:** $(date)

---

## VM Profile

| Field | Value |
|-------|-------|
| Hostname | $vm_hostname |
| OS | $vm_os |
| CPU | ${vm_cpu} vCPUs |
| Memory | ${vm_mem}GB |
| IP | $primary_ip |

## Listening TCP Ports

\`$tcp_ports\`

## Azure Recommendation

| Resource | Value |
|----------|-------|
| VM Size | **$vm_size** |
| OS Disk | ${os_disk_gb}GB SSD |
| Data Disk | ${data_disk_gb}GB SSD |

## Generated Files

| File | Purpose |
|------|---------|
| \`vm_resources.json\` | OS, CPU, memory |
| \`listening_ports.json\` | All listening ports |
| \`network.json\` | Interfaces, routes, DNS |
| \`firewall.json\` | Firewall rules |
| \`services.json\` | Running/enabled services |
| \`azure_nsg_rules.json\` | Ready-to-apply NSG rules |
| \`terraform_vars.auto.tfvars\` | Terraform variables |

## Next Steps

\`\`\`bash
# 1. Fill in your subscription_id and tenant_id:
vi $TERRAFORM_VARS_FILE

# 2. Copy to terraform directory and deploy:
cp $TERRAFORM_VARS_FILE ../terraform/
cd ../terraform
terraform init && terraform plan && terraform apply
\`\`\`
EOF

    ok "Report saved: $OUTPUT_DIR/DISCOVERY_REPORT.md"
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    preflight
    discover_vm_resources
    discover_listening_ports
    discover_network
    discover_firewall
    discover_services
    generate_azure_nsg_rules
    generate_terraform_vars
    generate_report

    header "Discovery Complete"
    ok "All data saved to: $OUTPUT_DIR"
    echo ""
    echo "  Report  : $OUTPUT_DIR/DISCOVERY_REPORT.md"
    echo "  NSG     : $NSG_RULES_FILE"
    echo "  TF vars : $TERRAFORM_VARS_FILE"
    echo ""
    echo -e "${CYAN}Next step:${NC} edit $TERRAFORM_VARS_FILE (add subscription_id + tenant_id)"
    echo ""
}

main
