terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Backend values come from the workflow (-backend-config), same pattern as the
  # AWS stack. use_oidc lets the federated GitHub token reach the state
  # container too: without it Terraform authenticates the provider with OIDC and
  # then fails on the very first state read.
  backend "azurerm" {
    use_oidc = true
  }
}

provider "azurerm" {
  features {
    virtual_machine {
      # A `terraform destroy` must take the OS disk with it, otherwise the lab
      # leaves a paid managed disk behind every time.
      delete_os_disk_on_deletion = true
    }
  }

  # Set from ARM_CLIENT_ID / ARM_TENANT_ID / ARM_SUBSCRIPTION_ID in CI.
  use_oidc = true
}
