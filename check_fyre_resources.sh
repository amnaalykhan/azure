#!/bin/bash

################################################################################
# Fyre VM Resource Check Script
# Purpose: Check CPU, RAM, Disk, and other resources on Fyre Linux VM
#          to help plan AWS migration sizing
################################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Output file
OUTPUT_FILE="fyre_vm_resources_$(date +%Y%m%d_%H%M%S).txt"

################################################################################
# Helper Functions
################################################################################

print_header() {
    local title="$1"
    echo ""
    echo "================================================================================"
    echo "  $title"
    echo "================================================================================"
    echo ""
}

print_section() {
    local title="$1"
    echo ""
    echo "--------------------------------------------------------------------------------"
    echo "  $title"
    echo "--------------------------------------------------------------------------------"
}

log_output() {
    tee -a "$OUTPUT_FILE"
}

################################################################################
# Resource Check Functions
################################################################################

check_system_info() {
    print_header "System Information" | log_output
    
    echo "Hostname: $(hostname)" | log_output
    echo "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)" | log_output
    echo "Kernel: $(uname -r)" | log_output
    echo "Architecture: $(uname -m)" | log_output
    echo "Uptime: $(uptime -p 2>/dev/null || uptime)" | log_output
    echo "Current Date: $(date)" | log_output
}

check_cpu_info() {
    print_header "CPU Information" | log_output
    
    # CPU Model and Count
    echo "CPU Model:" | log_output
    grep "model name" /proc/cpuinfo | head -1 | cut -d':' -f2 | sed 's/^[ \t]*//' | log_output
    
    echo "" | log_output
    echo "CPU Cores:" | log_output
    echo "  Physical CPUs: $(grep "physical id" /proc/cpuinfo | sort -u | wc -l)" | log_output
    echo "  CPU Cores: $(grep "cpu cores" /proc/cpuinfo | head -1 | cut -d':' -f2 | sed 's/^[ \t]*//')" | log_output
    echo "  vCPUs (threads): $(nproc)" | log_output
    
    echo "" | log_output
    echo "CPU Usage (current):" | log_output
    top -bn1 | grep "Cpu(s)" | log_output
    
    echo "" | log_output
    echo "Load Average:" | log_output
    uptime | awk -F'load average:' '{print $2}' | log_output
    
    echo "" | log_output
    echo "Top 5 CPU-consuming processes:" | log_output
    ps aux --sort=-%cpu | head -6 | log_output
}

check_memory_info() {
    print_header "Memory Information" | log_output
    
    echo "Memory Summary:" | log_output
    free -h | log_output
    
    echo "" | log_output
    echo "Detailed Memory Info:" | log_output
    echo "  Total RAM: $(free -h | awk '/^Mem:/ {print $2}')" | log_output
    echo "  Used RAM: $(free -h | awk '/^Mem:/ {print $3}')" | log_output
    echo "  Free RAM: $(free -h | awk '/^Mem:/ {print $4}')" | log_output
    echo "  Available RAM: $(free -h | awk '/^Mem:/ {print $7}')" | log_output
    echo "  RAM Usage %: $(free | awk '/^Mem:/ {printf "%.2f%%", $3/$2 * 100}')" | log_output
    
    echo "" | log_output
    echo "Swap Information:" | log_output
    echo "  Total Swap: $(free -h | awk '/^Swap:/ {print $2}')" | log_output
    echo "  Used Swap: $(free -h | awk '/^Swap:/ {print $3}')" | log_output
    echo "  Swap Usage %: $(free | awk '/^Swap:/ {if($2>0) printf "%.2f%%", $3/$2 * 100; else print "0%"}')" | log_output
    
    echo "" | log_output
    echo "Top 5 Memory-consuming processes:" | log_output
    ps aux --sort=-%mem | head -6 | log_output
}

check_disk_info() {
    print_header "Disk Information" | log_output
    
    echo "Disk Usage by Filesystem:" | log_output
    df -h | log_output
    
    echo "" | log_output
    echo "Disk Usage Summary:" | log_output
    df -h --total | tail -1 | log_output
    
    echo "" | log_output
    echo "Inode Usage:" | log_output
    df -i | log_output
    
    echo "" | log_output
    echo "Block Devices:" | log_output
    lsblk | log_output
    
    echo "" | log_output
    echo "Disk I/O Statistics:" | log_output
    if command -v iostat &> /dev/null; then
        iostat -x 1 2 | log_output
    else
        echo "  iostat not available (install sysstat package)" | log_output
    fi
    
    echo "" | log_output
    echo "Top 10 Largest Directories in /:" | log_output
    du -h --max-depth=1 / 2>/dev/null | sort -hr | head -10 | log_output
}

check_network_info() {
    print_header "Network Information" | log_output
    
    echo "Network Interfaces:" | log_output
    ip addr show | log_output
    
    echo "" | log_output
    echo "Network Statistics:" | log_output
    netstat -i 2>/dev/null || ip -s link | log_output
    
    echo "" | log_output
    echo "Active Network Connections:" | log_output
    netstat -tuln 2>/dev/null | head -20 || ss -tuln | head -20 | log_output
    
    echo "" | log_output
    echo "Routing Table:" | log_output
    ip route show | log_output
}

check_tws_specific() {
    print_header "TWS/Application Specific Information" | log_output
    
    # Check if TWS is installed
    if [ -d "/opt/ibm/TWA" ]; then
        echo "TWS Installation Found: /opt/ibm/TWA" | log_output
        echo "" | log_output
        
        echo "TWS Directory Size:" | log_output
        du -sh /opt/ibm/TWA 2>/dev/null | log_output
        
        echo "" | log_output
        echo "TWS Subdirectories:" | log_output
        du -sh /opt/ibm/TWA/* 2>/dev/null | sort -hr | log_output
        
        echo "" | log_output
        echo "TWS Processes:" | log_output
        ps aux | grep -i tws | grep -v grep | log_output
        
        echo "" | log_output
        echo "TWS User Info:" | log_output
        if id tws &>/dev/null; then
            id tws | log_output
            echo "TWS User Home: $(eval echo ~tws)" | log_output
        else
            echo "TWS user not found" | log_output
        fi
    else
        echo "TWS not found in /opt/ibm/TWA" | log_output
    fi
    
    # Check for DB2
    if [ -d "/opt/ibm/db2" ] || command -v db2level &>/dev/null; then
        echo "" | log_output
        echo "DB2 Installation Found" | log_output
        if command -v db2level &>/dev/null; then
            db2level 2>/dev/null | log_output || echo "DB2 not accessible" | log_output
        fi
    fi
}

check_running_services() {
    print_header "Running Services" | log_output
    
    if command -v systemctl &> /dev/null; then
        echo "Active Services (systemd):" | log_output
        systemctl list-units --type=service --state=running | log_output
    else
        echo "Service Status (init.d):" | log_output
        service --status-all 2>&1 | grep running | log_output
    fi
}

check_resource_limits() {
    print_header "System Resource Limits" | log_output
    
    echo "Current User Limits:" | log_output
    ulimit -a | log_output
    
    echo "" | log_output
    echo "System-wide Limits:" | log_output
    if [ -f /etc/security/limits.conf ]; then
        echo "From /etc/security/limits.conf:" | log_output
        grep -v "^#" /etc/security/limits.conf | grep -v "^$" | log_output
    fi
}

generate_aws_recommendations() {
    print_header "AWS EC2 Instance Recommendations" | log_output
    
    # Get current resources
    local total_ram_gb=$(free -g | awk '/^Mem:/ {print $2}')
    local vcpus=$(nproc)
    local total_disk_gb=$(df -BG --total | tail -1 | awk '{print $2}' | sed 's/G//')
    
    echo "Current Fyre VM Resources:" | log_output
    echo "  vCPUs: $vcpus" | log_output
    echo "  RAM: ${total_ram_gb}GB" | log_output
    echo "  Disk: ${total_disk_gb}GB" | log_output
    
    echo "" | log_output
    echo "Recommended AWS EC2 Instance Types:" | log_output
    echo "" | log_output
    
    # Recommendations based on resources
    if [ "$vcpus" -le 2 ] && [ "$total_ram_gb" -le 8 ]; then
        echo "  Small Workload:" | log_output
        echo "    - t3.medium (2 vCPU, 4GB RAM) - Burstable, cost-effective" | log_output
        echo "    - t3.large (2 vCPU, 8GB RAM) - More memory" | log_output
        echo "    - m5.large (2 vCPU, 8GB RAM) - General purpose, consistent performance" | log_output
    elif [ "$vcpus" -le 4 ] && [ "$total_ram_gb" -le 16 ]; then
        echo "  Medium Workload:" | log_output
        echo "    - t3.xlarge (4 vCPU, 16GB RAM) - Burstable" | log_output
        echo "    - m5.xlarge (4 vCPU, 16GB RAM) - General purpose" | log_output
        echo "    - c5.xlarge (4 vCPU, 8GB RAM) - Compute optimized" | log_output
    elif [ "$vcpus" -le 8 ] && [ "$total_ram_gb" -le 32 ]; then
        echo "  Large Workload:" | log_output
        echo "    - m5.2xlarge (8 vCPU, 32GB RAM) - General purpose" | log_output
        echo "    - c5.2xlarge (8 vCPU, 16GB RAM) - Compute optimized" | log_output
        echo "    - r5.2xlarge (8 vCPU, 64GB RAM) - Memory optimized" | log_output
    else
        echo "  Extra Large Workload:" | log_output
        echo "    - m5.4xlarge (16 vCPU, 64GB RAM) - General purpose" | log_output
        echo "    - c5.4xlarge (16 vCPU, 32GB RAM) - Compute optimized" | log_output
        echo "    - r5.4xlarge (16 vCPU, 128GB RAM) - Memory optimized" | log_output
    fi
    
    echo "" | log_output
    echo "EBS Volume Recommendations:" | log_output
    echo "  Root Volume: 30-50GB (gp3)" | log_output
    echo "  Data Volume: ${total_disk_gb}GB+ (gp3 or io2 for high IOPS)" | log_output
    
    echo "" | log_output
    echo "Note: Add 20-30% overhead for OS, logs, and growth" | log_output
}

################################################################################
# Main Execution
################################################################################

main() {
    echo "================================================================================"
    echo "  Fyre VM Resource Check for AWS Migration"
    echo "  Started: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "================================================================================"
    echo ""
    echo "Output will be saved to: $OUTPUT_FILE"
    echo ""
    
    # Initialize output file
    {
        echo "================================================================================"
        echo "  Fyre VM Resource Report"
        echo "  Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  Hostname: $(hostname)"
        echo "================================================================================"
    } > "$OUTPUT_FILE"
    
    # Run all checks
    check_system_info
    check_cpu_info
    check_memory_info
    check_disk_info
    check_network_info
    check_tws_specific
    check_running_services
    check_resource_limits
    generate_aws_recommendations
    
    # Final summary
    print_header "Summary" | log_output
    echo "Resource check completed successfully!" | log_output
    echo "Full report saved to: $OUTPUT_FILE" | log_output
    echo "" | log_output
    echo "Next Steps:" | log_output
    echo "  1. Review the report to understand current resource usage" | log_output
    echo "  2. Check AWS EC2 instance recommendations" | log_output
    echo "  3. Update terraform/variables.tf with appropriate instance type" | log_output
    echo "  4. Ensure EBS volumes are sized appropriately" | log_output
    echo "" | log_output
    
    echo ""
    echo -e "${GREEN}✓ Resource check completed!${NC}"
    echo -e "Report saved to: ${BLUE}$OUTPUT_FILE${NC}"
}

# Execute main function
main "$@"

# Made with Bob
