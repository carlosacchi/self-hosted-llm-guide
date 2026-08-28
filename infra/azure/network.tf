resource "azurerm_resource_group" "llm" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.lab_tags
}

resource "azurerm_virtual_network" "llm" {
  name                = "llm-gpu-vnet"
  address_space       = [var.vnet_cidr]
  location            = azurerm_resource_group.llm.location
  resource_group_name = azurerm_resource_group.llm.name
  tags                = local.lab_tags
}

# One subnet, one VM. There is no internet gateway to create: on Azure outbound
# internet works by default and a public IP attached to the NIC provides inbound.
resource "azurerm_subnet" "public" {
  name                 = "llm-gpu-subnet"
  resource_group_name  = azurerm_resource_group.llm.name
  virtual_network_name = azurerm_virtual_network.llm.name
  address_prefixes     = [var.subnet_cidr]
}

resource "azurerm_network_security_group" "llm_gpu" {
  name                = "llm-gpu-nsg"
  location            = azurerm_resource_group.llm.location
  resource_group_name = azurerm_resource_group.llm.name
  tags                = local.lab_tags

  # Azure evaluates rules by priority and applies a default deny at 65500, so
  # only the allow rules need to be declared. Egress is unrestricted by default,
  # which matches the AWS security group's open egress.
  dynamic "security_rule" {
    for_each = local.ingress_ports
    content {
      name                       = "allow-${security_rule.key}"
      description                = security_rule.value
      priority                   = 1000 + index(keys(local.ingress_ports), security_rule.key)
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = tostring(security_rule.key)
      source_address_prefix      = local.ingress_ipv4_cidr
      destination_address_prefix = "*"
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "llm_gpu" {
  subnet_id                 = azurerm_subnet.public.id
  network_security_group_id = azurerm_network_security_group.llm_gpu.id
}

# Unlike the AWS Elastic IP, this can be bound at plan time: there is no Auto
# Scaling group choosing the instance, so the address is attached to the NIC
# directly and the in-VM AssociateAddress dance in user-data.sh disappears.
#
# Static + Standard is required, not cosmetic: a Basic or Dynamic public IP
# changes address every time the VM is deallocated, and this lab deallocates
# several times a day.
resource "azurerm_public_ip" "llm_gpu" {
  name                = "llm-gpu-ip"
  location            = azurerm_resource_group.llm.location
  resource_group_name = azurerm_resource_group.llm.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.lab_tags
}

resource "azurerm_network_interface" "llm_gpu" {
  name                = "llm-gpu-nic"
  location            = azurerm_resource_group.llm.location
  resource_group_name = azurerm_resource_group.llm.name
  tags                = local.lab_tags

  accelerated_networking_enabled = true

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.public.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.llm_gpu.id
  }
}
