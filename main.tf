terraform {
  required_version = ">= 0.15.4"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 2.23"
    }
  }
}

provider "azurerm" {
  skip_provider_registration = true
  features {}
}

resource "azurerm_resource_group" "rgsqlteste" {
    name     = "rgsqlteste"
    location = "eastus"

    tags     = {
        "Environment" = "aula terraform"
    }
}

resource "azurerm_virtual_network" "vnsqlteste" {
    name                = "vnsqlteste"
    address_space       = ["10.0.0.0/16"]
    location            = "eastus"
    resource_group_name = azurerm_resource_group.rgsqlteste.name
}

resource "azurerm_subnet" "subnetsqlteste" {
    name                 = "subnetsqlteste"
    resource_group_name  = azurerm_resource_group.rgsqlteste.name
    virtual_network_name = azurerm_virtual_network.vnsqlteste.name
    address_prefixes       = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "publicipsqlteste" {
    name                         = "publicipsqlteste"
    location                     = "eastus"
    resource_group_name          = azurerm_resource_group.rgsqlteste.name
    allocation_method            = "Static"
}

resource "azurerm_network_security_group" "nsgsqlteste" {
    name                = "nsgsqlteste"
    location            = "eastus"
    resource_group_name = azurerm_resource_group.rgsqlteste.name

    security_rule {
        name                       = "sql"
        priority                   = 1001
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "3306"
        source_address_prefix      = "*"
        destination_address_prefix = "*"
    }

    security_rule {
        name                       = "SSH"
        priority                   = 1002
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "22"
        source_address_prefix      = "*"
        destination_address_prefix = "*"
    }
}

resource "azurerm_network_interface" "nicsqlteste" {
    name                      = "nicsqlteste"
    location                  = "eastus"
    resource_group_name       = azurerm_resource_group.rgsqlteste.name

    ip_configuration {
        name                          = "NicConfiguration"
        subnet_id                     = azurerm_subnet.subnetsqlteste.id
        private_ip_address_allocation = "Dynamic"
        public_ip_address_id          = azurerm_public_ip.publicipsqlteste.id
    }
}

resource "azurerm_network_interface_security_group_association" "example" {
    network_interface_id      = azurerm_network_interface.nicsqlteste.id
    network_security_group_id = azurerm_network_security_group.nsgsqlteste.id
}

data "azurerm_public_ip" "ip_aula_data_db" {
  name                = azurerm_public_ip.publicipsqlteste.name
  resource_group_name = azurerm_resource_group.rgsqlteste.name
}

resource "azurerm_storage_account" "smsqlteste" {
    name                        = "storagevm"
    resource_group_name         = azurerm_resource_group.rgsqlteste.name
    location                    = "eastus"
    account_tier                = "Standard"
    account_replication_type    = "LRS"
}

resource "azurerm_linux_virtual_machine" "vmsqlteste" {
    name                  = "sqlteste"
    location              = "eastus"
    resource_group_name   = azurerm_resource_group.rgsqlteste.name
    network_interface_ids = [azurerm_network_interface.nicsqlteste.id]
    size                  = "Standard_DS1_v2"

    os_disk {
        name              = "OsDiskSQL"
        caching           = "ReadWrite"
        storage_account_type = "Premium_LRS"
    }

    source_image_reference {
        publisher = "Canonical"
        offer     = "UbuntuServer"
        sku       = "18.04-LTS"
        version   = "latest"
    }

    computer_name  = "vm"
    admin_username = var.user
    admin_password = var.password
    disable_password_authentication = false

    boot_diagnostics {
        storage_account_uri = azurerm_storage_account.smsqlteste.primary_blob_endpoint
    }

    depends_on = [ azurerm_resource_group.rgsqlteste ]
}

output "public_ip_address_sql" {
  value = azurerm_public_ip.publicipsqlteste.ip_address
}

resource "time_sleep" "wait_30_seconds_db" {
  depends_on = [azurerm_linux_virtual_machine.vmsqlteste]
  create_duration = "30s"
}

resource "null_resource" "upload_db" {
    provisioner "file" {
        connection {
            type = "ssh"
            user = var.user
            password = var.password
            host = data.azurerm_public_ip.ip_aula_data_db.ip_address
        }
        source = "config"
        destination = "/home/azureuser"
    }

    depends_on = [ time_sleep.wait_30_seconds_db ]
}

resource "null_resource" "deploy_db" {
    triggers = {
        order = null_resource.upload_db.id
    }
    provisioner "remote-exec" {
        connection {
            type = "ssh"
            user = var.user
            password = var.password
            host = data.azurerm_public_ip.ip_aula_data_db.ip_address
        }
        inline = [
            "sudo apt-get update",
            "sudo apt-get install -y sql-server-5.7",
            "sudo sql < /home/azureuser/config/user.sql",
            "sudo cp -f /home/azureuser/config/sqld.cnf /etc/sql/sql.conf.d/sqld.cnf",
            "sudo service sql restart",
            "sleep 30",
        ]
    }
}