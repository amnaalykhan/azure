#!/bin/bash

################################################################################
# Approach 2 — Phase 1: Deep Discovery
#
# Mirrors discover_fyre_network.sh from Approach 1, but outputs a structured
# discovery bundle that all subsequent Approach 2 scripts consume.
#
# Usage:
#   ./01_discover.sh <source-vm-hostname> [ssh-user]
#
# Example:
#   ./01_discover.sh itz-693000iler-gw3v1m6w.dev.fyre.ibm.com root
#   ./01_discover.sh myvm.on-prem.example.com ubuntu
#
# Output:
#   discovery_<timestamp>/
#     vm_profile.json        — OS, CPU, RAM, hostname
#     disks.json             — all block devices and mount points
#     network.json           — interfaces, IPs, routes, DNS
#     listening_ports.json   — TCP/UDP ports + owning process
#     firewall.json          — firewalld/iptables rules
#     services.json          — systemd services (running/enabled)
#     azure_sizing.json      — recommended Azure VM size + disk sizes
#     azure_nsg_rules.json   — ready-to-apply NSG rules from discovered ports
#     DISCOVERY_REPORT.md    — human-readable summary
################################################################################

set -euo pipefail

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

# ── Arguments ──────────────────────────────────────────────────────────────────
SOURCE_VM="${1:-}"
SSH_USER="${2:-root}"
OUTPUT_DIR="discovery_$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$OUTPUT_DIR/discovery.log"

# ── Helpers ───────────────────────────────────────────────────────────────────
print_banner() {
    echo -e "${CYAN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║   Approach 2 — Phase 1: Source VM Deep Discovery             ║
║   Fyre / On-Premise  →  Azure Migrate                        ║
╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

header()  { echo -e "\n${CYAN}══ $1 ══${NC}"; }
section() { echo -e "\n${BLUE}── $1 ──${NC}"; }
ok()      { echo -e "${GREEN}✓${NC} $1" | tee -a "$LOG_FILE"; }
info()    { echo -e "${BLUE}ℹ${NC} $1"  | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1" | tee -a "$LOG_FILE"; }
die()     { echo -e "${RED}✗ FATAL:${NC} $1" | tee -a "$LOG_FILE"; exit 1; }

# Run a command on the source VM
remote() { ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no "${SSH_USER}@${SOURCE_VM}" "$@" 2>/dev/null; }

# Safely run remote command, return empty string on failure
remote_safe() { ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no "${SSH_USER}@${SOURCE_VM}" "$@" 2>/dev/null || echo ""; }

################################################################################
# Preflight
################################################################################

preflight() {
    header "Preflight Checks"

    [[ -z "$SOURCE_VM" ]] && {
        echo "Usage: $0 <source-vm-hostname> [ssh-user]"
        echo "Example: $0 myvm.fyre.ibm.com root"
        exit 1
    }

    command -v ssh  &>/dev/null || die "ssh not installed"
    command -v jq   &>/dev/null || die "jq not installed (brew install jq / apt install jq)"

    mkdir -p "$OUTPUT_DIR"
    info "Output directory: $OUTPUT_DIR"
    info "SSH target: ${SSH_USER}@${SOURCE_VM}"

    # Verify SSH works
    info "Testing SSH connection..."
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no \
            "${SSH_USER}@${SOURCE_VM}" "echo connected" &>/dev/null; then
        die "Cannot SSH to ${SSH_USER}@${SOURCE_VM}. Check connectivity and SSH keys."
    fi
    ok "SSH connection successful"
}

################################################################################
# Phase 1A: VM Profile (OS, CPU, RAM, hostname)
################################################################################

discover_vm_profile() {
    section "VM Profile"
    info "Collecting OS, CPU, memory..."

    HOSTNAME=$(remote_safe "hostname")
    OS_PRETTY=$(remote_safe "cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'\"' -f2")
    OS_NAME=$(remote_safe "cat /etc/os-release 2>/dev/null | grep '^NAME=' | cut -d'\"' -f2")
    OS_VERSION=$(remote_safe "cat /etc/os-release 2>/dev/null | grep '^VERSION=' | cut -d'\"' -f2")
    OS_ID=$(remote_safe "cat /etc/os-release 2>/dev/null | grep '^ID=' | cut -d'=' -f2 | tr -d '\"'")
    KERNEL=$(remote_safe "uname -r")
    ARCH=$(remote_safe "uname -m")
    CPU_COUNT=$(remote_safe "nproc")
    CPU_MODEL=$(remote_safe "grep 'model name' /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs")
    MEM_TOTAL_GB=$(remote_safe "awk '/MemTotal/ {printf \"%.0f\", \$2/1024/1024}' /proc/meminfo")
    MEM_FREE_GB=$(remote_safe  "awk '/MemAvailable/ {printf \"%.0f\", \$2/1024/1024}' /proc/meminfo")

    cat > "$OUTPUT_DIR/vm_profile.json" <<EOF
{
  "hostname": "$HOSTNAME",
  "fqdn": "$SOURCE_VM",
  "ssh_user": "$SSH_USER",
  "os": {
    "pretty_name": "$OS_PRETTY",
    "name": "$OS_NAME",
    "version": "$OS_VERSION",
    "id": "$OS_ID",
    "kernel": "$KERNEL",
    "architecture": "$ARCH"
  },
  "cpu": {
    "count": $CPU_COUNT,
    "model": "$CPU_MODEL"
  },
  "memory_gb": {
    "total": $MEM_TOTAL_GB,
    "available": $MEM_FREE_GB
  },
  "discovered_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

    ok "VM profile saved"
    echo "  Hostname : $HOSTNAME"
    echo "  OS       : $OS_PRETTY"
    echo "  CPU      : ${CPU_COUNT} cores ($CPU_MODEL)"
    echo "  Memory   : ${MEM_TOTAL_GB}GB total"
}

################################################################################
# Phase 1B: Disk Layout
################################################################################

discover_disks() {
    section "Disk Layout"
    info "Scanning block devices and mount points..."

    DISK_JSON=$(remote_safe "lsblk -b -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,LABEL -J 2>/dev/null || echo '{\"blockdevices\":[]}'")
    DF_DATA=$(remote_safe "df -BG 2>/dev/null | tail -n +2")
    TOTAL_USED_GB=$(remote_safe "df -BG --total 2>/dev/null | tail -1 | awk '{print \$3}' | sed 's/G//'")
    TOTAL_SIZE_GB=$(remote_safe "df -BG --total 2>/dev/null | tail -1 | awk '{print \$2}' | sed 's/G//'")

    cat > "$OUTPUT_DIR/disks.json" <<EOF
{
  "block_devices": $DISK_JSON,
  "filesystem_summary": {
    "total_size_gb": ${TOTAL_SIZE_GB:-0},
    "total_used_gb": ${TOTAL_USED_GB:-0}
  },
  "df_output": $(echo "$DF_DATA" | jq -R -s 'split("\n") | map(select(length>0))')
}
EOF

    ok "Disk layout saved"
    echo "  Total disk used : ${TOTAL_USED_GB:-0}GB / ${TOTAL_SIZE_GB:-0}GB"
}

################################################################################
# Phase 1C: Network Configuration
################################################################################

discover_network() {
    section "Network Configuration"
    info "Collecting interfaces, routes, DNS..."

    # Interfaces
    IFACE_JSON=$(remote_safe "ip -j addr show 2>/dev/null || echo '[]'")
    # Routes
    ROUTE_JSON=$(remote_safe "ip -j route show 2>/dev/null || echo '[]'")
    GATEWAY=$(remote_safe "ip route | grep default | awk '{print \$3}' | head -1")
    # DNS
    NAMESERVERS=$(remote_safe "grep '^nameserver' /etc/resolv.conf | awk '{print \$2}' | paste -sd,")
    SEARCH_DOMAINS=$(remote_safe "grep '^search' /etc/resolv.conf | cut -d' ' -f2-")
    # Primary IP
    PRIMARY_IP=$(remote_safe "hostname -I | awk '{print \$1}'")

    cat > "$OUTPUT_DIR/network.json" <<EOF
{
  "primary_ip": "$PRIMARY_IP",
  "default_gateway": "$GATEWAY",
  "interfaces": $IFACE_JSON,
  "routes": $ROUTE_JSON,
  "dns": {
    "nameservers": "$NAMESERVERS",
    "search_domains": "$SEARCH_DOMAINS"
  },
  "hosts_file": $(remote_safe "cat /etc/hosts 2>/dev/null" | jq -R -s '.')
}
EOF

    ok "Network config saved"
    echo "  Primary IP      : $PRIMARY_IP"
    echo "  Default gateway : $GATEWAY"
    echo "  DNS servers     : $NAMESERVERS"
}

################################################################################
# Phase 1D: Listening Ports + Process Owners
################################################################################

discover_ports() {
    section "Listening Ports"
    info "Scanning TCP and UDP listening ports..."

    TCP_PORTS=$(remote_safe "ss -tlnp 2>/dev/null | awk 'NR>1 && /LISTEN/ {print \$4}' | sed 's/.*://' | sort -un")
    UDP_PORTS=$(remote_safe "ss -ulnp 2>/dev/null | awk 'NR>1 {print \$4}' | sed 's/.*://' | sort -un")

    # Build JSON array of {port, protocol, process}
    TCP_ARRAY="["
    while IFS= read -r port; do
        [[ -z "$port" || "$port" == "0" ]] && continue
        proc=$(remote_safe "ss -tlnp 2>/dev/null | awk '/:\b${port}\b/ {print \$6}' | head -1 | sed 's/.*\"\(.*\)\".*/\1/' | sed 's/[^a-zA-Z0-9_-]/-/g'")
        [[ -z "$proc" ]] && proc="unknown"
        TCP_ARRAY+="{\"port\":$port,\"protocol\":\"tcp\",\"process\":\"$proc\"},"
    done <<< "$TCP_PORTS"
    TCP_ARRAY="${TCP_ARRAY%,}]"

    UDP_ARRAY="["
    while IFS= read -r port; do
        [[ -z "$port" || "$port" == "0" ]] && continue
        UDP_ARRAY+="{\"port\":$port,\"protocol\":\"udp\"},"
    done <<< "$UDP_PORTS"
    UDP_ARRAY="${UDP_ARRAY%,}]"

    cat > "$OUTPUT_DIR/listening_ports.json" <<EOF
{
  "tcp": $TCP_ARRAY,
  "udp": $UDP_ARRAY
}
EOF

    ok "Listening ports saved"
    echo "  TCP ports : $(echo "$TCP_PORTS" | grep -c '[0-9]' || echo 0)"
    echo "  UDP ports : $(echo "$UDP_PORTS" | grep -c '[0-9]' || echo 0)"
    echo ""
    echo "  TCP: $(echo "$TCP_PORTS" | tr '\n' ' ')"
}

################################################################################
# Phase 1E: Firewall Rules
################################################################################

discover_firewall() {
    section "Firewall Rules"

    FIREWALL_TYPE="none"

    if remote_safe "systemctl is-active firewalld 2>/dev/null" | grep -q "^active"; then
        FIREWALL_TYPE="firewalld"
        info "Detected: firewalld"
        FW_DEFAULT_ZONE=$(remote_safe "firewall-cmd --get-default-zone 2>/dev/null")
        FW_SERVICES=$(remote_safe "firewall-cmd --list-services 2>/dev/null")
        FW_PORTS=$(remote_safe "firewall-cmd --list-ports 2>/dev/null")
        FW_RICH=$(remote_safe "firewall-cmd --list-rich-rules 2>/dev/null")
        FW_ALL=$(remote_safe "firewall-cmd --list-all 2>/dev/null" | jq -R -s '.')
        cat > "$OUTPUT_DIR/firewall.json" <<EOF
{
  "type": "firewalld",
  "default_zone": "$FW_DEFAULT_ZONE",
  "services": "$FW_SERVICES",
  "ports": "$FW_PORTS",
  "rich_rules": "$FW_RICH",
  "full_output": $FW_ALL
}
EOF

    elif remote_safe "iptables -L -n 2>/dev/null | wc -l" | grep -qv "^[0-3]$"; then
        FIREWALL_TYPE="iptables"
        info "Detected: iptables"
        IPTABLES=$(remote_safe "iptables-save 2>/dev/null" | jq -R -s '.')
        cat > "$OUTPUT_DIR/firewall.json" <<EOF
{
  "type": "iptables",
  "rules": $IPTABLES
}
EOF
    else
        warn "No active firewall detected"
        echo '{"type":"none"}' > "$OUTPUT_DIR/firewall.json"
    fi

    ok "Firewall config saved (type: $FIREWALL_TYPE)"
}

################################################################################
# Phase 1F: Running & Enabled Services
################################################################################

discover_services() {
    section "System Services"
    info "Listing running and enabled systemd services..."

    RUNNING=$(remote_safe "systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print \$1}'" | jq -R -s 'split("\n") | map(select(length>0))')
    ENABLED=$(remote_safe "systemctl list-unit-files --type=service --state=enabled --no-legend 2>/dev/null | awk '{print \$1}'" | jq -R -s 'split("\n") | map(select(length>0))')

    cat > "$OUTPUT_DIR/services.json" <<EOF
{
  "running": $RUNNING,
  "enabled": $ENABLED
}
EOF

    RUNNING_COUNT=$(echo "$RUNNING" | jq 'length' 2>/dev/null || echo 0)
    ok "Services saved ($RUNNING_COUNT running)"
}

################################################################################
# Phase 1G: Azure Sizing Recommendation
################################################################################

generate_azure_sizing() {
    section "Azure Sizing"
    info "Calculating recommended Azure VM size..."

    CPU_COUNT=$(jq -r '.cpu.count' "$OUTPUT_DIR/vm_profile.json")
    MEM_GB=$(jq -r '.memory_gb.total' "$OUTPUT_DIR/vm_profile.json")
    DISK_USED=$(jq -r '.filesystem_summary.total_used_gb' "$OUTPUT_DIR/disks.json")
    DISK_TOTAL=$(jq -r '.filesystem_summary.total_size_gb' "$OUTPUT_DIR/disks.json")

    # VM size recommendation
    if   [[ $CPU_COUNT -le 2  && $MEM_GB -le 8  ]]; then VM_SIZE="Standard_D2s_v3"
    elif [[ $CPU_COUNT -le 4  && $MEM_GB -le 16 ]]; then VM_SIZE="Standard_D4s_v3"
    elif [[ $CPU_COUNT -le 8  && $MEM_GB -le 32 ]]; then VM_SIZE="Standard_D8s_v3"
    elif [[ $CPU_COUNT -le 16 && $MEM_GB -le 64 ]]; then VM_SIZE="Standard_D16s_v3"
    else VM_SIZE="Standard_D32s_v3"; fi

    # Memory-optimised override
    if [[ $MEM_GB -gt $((CPU_COUNT * 6)) ]]; then
        if   [[ $CPU_COUNT -le 4  ]]; then VM_SIZE="Standard_E4s_v3"
        elif [[ $CPU_COUNT -le 8  ]]; then VM_SIZE="Standard_E8s_v3"
        else VM_SIZE="Standard_E16s_v3"; fi
    fi

    # OS disk = max(disk_total, 128), data disk = disk_used + 20% headroom
    OS_DISK_GB=$(( DISK_TOTAL > 128 ? DISK_TOTAL : 128 ))
    DATA_DISK_GB=$(( (DISK_USED * 120) / 100 ))
    DATA_DISK_GB=$(( DATA_DISK_GB > 32 ? DATA_DISK_GB : 32 ))

    cat > "$OUTPUT_DIR/azure_sizing.json" <<EOF
{
  "source": {
    "cpu_count": $CPU_COUNT,
    "memory_gb": $MEM_GB,
    "disk_total_gb": $DISK_TOTAL,
    "disk_used_gb": $DISK_USED
  },
  "recommended": {
    "vm_size": "$VM_SIZE",
    "os_disk_gb": $OS_DISK_GB,
    "os_disk_type": "Premium_LRS",
    "data_disk_gb": $DATA_DISK_GB,
    "data_disk_type": "Premium_LRS"
  }
}
EOF

    ok "Azure sizing saved"
    echo "  Recommended VM size : $VM_SIZE"
    echo "  OS disk             : ${OS_DISK_GB}GB Premium SSD"
    echo "  Data disk           : ${DATA_DISK_GB}GB Premium SSD"
}

################################################################################
# Phase 1H: Generate Azure NSG Rules from Discovered Ports
################################################################################

generate_nsg_rules() {
    section "Azure NSG Rules"
    info "Converting discovered ports to Azure NSG rules..."

    PRIORITY=100
    NSG_ARRAY="["

    # Always include SSH
    NSG_ARRAY+="{\"name\":\"SSH\",\"priority\":$PRIORITY,\"direction\":\"Inbound\",\"access\":\"Allow\",\"protocol\":\"Tcp\",\"source_port_range\":\"*\",\"destination_port_range\":\"22\",\"source_address_prefix\":\"*\",\"destination_address_prefix\":\"*\"},"
    PRIORITY=$((PRIORITY + 10))

    # Add rule for each discovered TCP port (skip 22 — already added)
    while IFS= read -r entry; do
        port=$(echo "$entry" | jq -r '.port')
        proc=$(echo "$entry" | jq -r '.process')
        [[ "$port" == "22" ]] && continue
        [[ -z "$port" || "$port" == "null" ]] && continue
        name="Port-${port}"
        [[ "$proc" != "unknown" && "$proc" != "null" && -n "$proc" ]] && name="$proc-${port}"
        # Sanitise name for Azure (letters, numbers, hyphens only, max 80 chars)
        name=$(echo "$name" | sed 's/[^a-zA-Z0-9-]/-/g' | cut -c1-80)
        NSG_ARRAY+="{\"name\":\"$name\",\"priority\":$PRIORITY,\"direction\":\"Inbound\",\"access\":\"Allow\",\"protocol\":\"Tcp\",\"source_port_range\":\"*\",\"destination_port_range\":\"$port\",\"source_address_prefix\":\"*\",\"destination_address_prefix\":\"*\"},"
        PRIORITY=$((PRIORITY + 10))
    done < <(jq -c '.tcp[]' "$OUTPUT_DIR/listening_ports.json" 2>/dev/null || true)

    # Outbound allow-all
    NSG_ARRAY+="{\"name\":\"AllowAllOutbound\",\"priority\":100,\"direction\":\"Outbound\",\"access\":\"Allow\",\"protocol\":\"*\",\"source_port_range\":\"*\",\"destination_port_range\":\"*\",\"source_address_prefix\":\"*\",\"destination_address_prefix\":\"*\"}"
    NSG_ARRAY+="]"

    echo "{ \"nsg_rules\": $NSG_ARRAY }" | jq . > "$OUTPUT_DIR/azure_nsg_rules.json"

    RULE_COUNT=$(jq '.nsg_rules | length' "$OUTPUT_DIR/azure_nsg_rules.json")
    ok "NSG rules saved ($RULE_COUNT rules)"
}

################################################################################
# Phase 1I: Human-Readable Report
################################################################################

generate_report() {
    section "Discovery Report"

    VM_HOSTNAME=$(jq -r '.hostname' "$OUTPUT_DIR/vm_profile.json")
    VM_OS=$(jq -r '.os.pretty_name' "$OUTPUT_DIR/vm_profile.json")
    VM_CPU=$(jq -r '.cpu.count' "$OUTPUT_DIR/vm_profile.json")
    VM_MEM=$(jq -r '.memory_gb.total' "$OUTPUT_DIR/vm_profile.json")
    VM_SIZE=$(jq -r '.recommended.vm_size' "$OUTPUT_DIR/azure_sizing.json")
    OS_DISK=$(jq -r '.recommended.os_disk_gb' "$OUTPUT_DIR/azure_sizing.json")
    DATA_DISK=$(jq -r '.recommended.data_disk_gb' "$OUTPUT_DIR/azure_sizing.json")
    PRIMARY_IP=$(jq -r '.primary_ip' "$OUTPUT_DIR/network.json")
    GATEWAY=$(jq -r '.default_gateway' "$OUTPUT_DIR/network.json")
    DNS=$(jq -r '.dns.nameservers' "$OUTPUT_DIR/network.json")
    TCP_PORTS=$(jq -r '.tcp[].port' "$OUTPUT_DIR/listening_ports.json" 2>/dev/null | tr '\n' ' ')

    cat > "$OUTPUT_DIR/DISCOVERY_REPORT.md" <<EOF
# Source VM Discovery Report

**VM:** $VM_HOSTNAME ($SOURCE_VM)
**Date:** $(date)
**Approach:** 2 — Azure Migrate

---

## VM Profile

| Field | Value |
|-------|-------|
| Hostname | $VM_HOSTNAME |
| OS | $VM_OS |
| CPU | ${VM_CPU} cores |
| Memory | ${VM_MEM}GB |
| Primary IP | $PRIMARY_IP |
| Default Gateway | $GATEWAY |
| DNS | $DNS |

---

## Disk Layout

$(jq -r '.df_output[]' "$OUTPUT_DIR/disks.json" 2>/dev/null | awk 'BEGIN{print "```"} {print} END{print "```"}')

---

## Listening TCP Ports

\`$TCP_PORTS\`

---

## Azure Sizing Recommendation

| Resource | Value |
|----------|-------|
| VM Size | **$VM_SIZE** |
| OS Disk | ${OS_DISK}GB Premium SSD |
| Data Disk | ${DATA_DISK}GB Premium SSD |

---

## Generated Files

| File | Purpose |
|------|---------|
| \`vm_profile.json\` | OS, CPU, memory |
| \`disks.json\` | Block devices, mount points |
| \`network.json\` | Interfaces, routes, DNS |
| \`listening_ports.json\` | All listening ports + processes |
| \`firewall.json\` | Firewall rules |
| \`services.json\` | Running/enabled services |
| \`azure_sizing.json\` | Recommended Azure VM size |
| \`azure_nsg_rules.json\` | Ready-to-apply NSG rules |

---

## Next Step

\`\`\`bash
./02_setup_azure_migrate.sh $SOURCE_VM $SSH_USER $OUTPUT_DIR
\`\`\`
EOF

    ok "Report written: $OUTPUT_DIR/DISCOVERY_REPORT.md"
}

################################################################################
# Main
################################################################################

main() {
    print_banner
    preflight
    discover_vm_profile
    discover_disks
    discover_network
    discover_ports
    discover_firewall
    discover_services
    generate_azure_sizing
    generate_nsg_rules
    generate_report

    header "Discovery Complete"
    ok "All discovery data saved to: ${MAGENTA}$OUTPUT_DIR${NC}"
    echo ""
    echo "  cat $OUTPUT_DIR/DISCOVERY_REPORT.md"
    echo ""
    echo -e "${CYAN}Next step:${NC}"
    echo "  ./02_setup_azure_migrate.sh \"$SOURCE_VM\" \"$SSH_USER\" \"$OUTPUT_DIR\""
    echo ""
}

main

# Made with Bob
