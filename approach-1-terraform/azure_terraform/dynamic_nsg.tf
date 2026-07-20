################################################################################
# Dynamic NSG Rules
#
# ALL NSG rules live here. main.tf intentionally has no inline security_rule
# blocks — mixing inline rules with azurerm_network_security_rule on the same
# NSG causes a Terraform/Azure conflict that prevents terraform apply.
#
# Rule sources:
#   1. Hardcoded baseline rules (SSH, TWS, DB2, Outbound)
#   2. Discovered rules loaded from discovered_nsg_rules.json (auto-copied by
#      migrate_any_fyre_vm.sh from the fyre_discovery_*/azure_nsg_rules.json)
################################################################################

locals {
  # Path where migrate_any_fyre_vm.sh copies the discovery NSG output
  nsg_rules_file = "${path.module}/discovered_nsg_rules.json"

  # Load discovered rules if file exists, otherwise empty
  discovered_rules = fileexists(local.nsg_rules_file) ? jsondecode(file(local.nsg_rules_file)) : { nsg_rules = [] }

  # Filter out any discovered rule that duplicates a baseline rule name
  baseline_names = toset(["SSH", "TWS-Master", "TWS-Agent", "DB2", "AllowAllOutbound"])
  extra_rules    = [for r in local.discovered_rules.nsg_rules : r if !contains(local.baseline_names, r.name)]

  # Final merged rule list: baselines first, then any extra discovered rules
  all_nsg_rules = concat(
    [
      {
        name                       = "SSH"
        priority                   = 100
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "22"
        source_address_prefix      = var.allowed_ssh_cidr
        destination_address_prefix = "*"
      },
      {
        name                       = "TWS-Master"
        priority                   = 110
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "31114"
        source_address_prefix      = var.allowed_tws_cidr
        destination_address_prefix = "*"
      },
      {
        name                       = "TWS-Agent"
        priority                   = 120
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "31116"
        source_address_prefix      = var.allowed_tws_cidr
        destination_address_prefix = "*"
      },
      {
        name                       = "DB2"
        priority                   = 130
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "50000"
        source_address_prefix      = var.allowed_db_cidr
        destination_address_prefix = "*"
      },
      {
        name                       = "AllowAllOutbound"
        priority                   = 100
        direction                  = "Outbound"
        access                     = "Allow"
        protocol                   = "*"
        source_port_range          = "*"
        destination_port_range     = "*"
        source_address_prefix      = "*"
        destination_address_prefix = "*"
      }
    ],
    local.extra_rules
  )
}

# Create all NSG rules as standalone resources (no inline rules in main.tf)
resource "azurerm_network_security_rule" "dynamic_rules" {
  for_each = { for rule in local.all_nsg_rules : rule.name => rule }

  name                        = each.value.name
  priority                    = each.value.priority
  direction                   = each.value.direction
  access                      = each.value.access
  protocol                    = each.value.protocol
  source_port_range           = each.value.source_port_range
  destination_port_range      = each.value.destination_port_range
  source_address_prefix       = each.value.source_address_prefix
  destination_address_prefix  = each.value.destination_address_prefix
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.app.name

  depends_on = [azurerm_network_security_group.app]
}

output "applied_nsg_rules" {
  description = "NSG rules applied to the VM"
  value = {
    total_rules = length(local.all_nsg_rules)
    rules = [for r in local.all_nsg_rules : {
      name     = r.name
      priority = r.priority
      port     = r.destination_port_range
      source   = r.source_address_prefix
    }]
  }
}

# Made with Bob
