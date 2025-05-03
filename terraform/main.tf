# Setup azurerm as a state backend
terraform {
  backend "azurerm" {
    resource_group_name  = "s"
    storage_account_name = "s" # Provide Storage Account name, where Terraform Remote state is stored
    container_name       = "t"
    key                  = ""
  }
}

# Configure the Microsoft Azure Provider
provider "azurerm" {
  features {}
  subscription_id = ""
}

locals {
  acr_full_name = "acr${var.ENV}${var.LOCATION}${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length  = 2
  special = false
  upper   = false
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "bdcc" {
  name     = "rg-${var.ENV}-${var.LOCATION}-${random_string.suffix.result}"
  location = var.LOCATION

  lifecycle {
    prevent_destroy = false
  }

  tags = {
    region = var.BDCC_REGION
    env    = var.ENV
  }
}

resource "azurerm_storage_account" "bdcc" {
  depends_on = [
  azurerm_resource_group.bdcc]

  name                     = "${var.ENV}${var.LOCATION}${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.bdcc.name
  location                 = azurerm_resource_group.bdcc.location
  account_tier             = "Standard"
  account_replication_type = var.STORAGE_ACCOUNT_REPLICATION_TYPE
  is_hns_enabled           = "true"

  network_rules {
    default_action = "Allow"
    ip_rules       = values(var.IP_RULES)
  }

  lifecycle {
    prevent_destroy = false
  }

  tags = {
    region = var.BDCC_REGION
    env    = var.ENV
  }
}

resource "azurerm_storage_data_lake_gen2_filesystem" "gen2_data" {
  depends_on = [
  azurerm_storage_account.bdcc]

  name               = ""
  storage_account_id = azurerm_storage_account.bdcc.id

  lifecycle {
    prevent_destroy = false
  }
}


resource "azurerm_kubernetes_cluster" "bdcc" {
  depends_on = [
  azurerm_resource_group.bdcc]

  name                = "aks-${var.ENV}-${var.LOCATION}-${random_string.suffix.result}"
  location            = azurerm_resource_group.bdcc.location
  resource_group_name = azurerm_resource_group.bdcc.name
  dns_prefix          = "bdcc${var.ENV}"

  default_node_pool {
    name       = "default"
    node_count = 1
    vm_size    = "Standard_D3_v2"
  }

  identity {
    type = "SystemAssigned"
  }

  tags = {
    region = var.BDCC_REGION
    env    = var.ENV
  }
}

provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.bdcc.kube_config.0.host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.bdcc.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.bdcc.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.bdcc.kube_config.0.cluster_ca_certificate)
}

resource "kubernetes_namespace" "confluent" {
  metadata {
    name = "confluent"
  }
}

# Create Azure Container Registry (ACR)
resource "azurerm_container_registry" "acr" {
  name                = local.acr_full_name
  resource_group_name = azurerm_resource_group.bdcc.name
  location            = azurerm_resource_group.bdcc.location
  sku                 = var.ACR_SKU
  admin_enabled       = false

  tags = {
    region = var.BDCC_REGION
    env    = var.ENV
  }
}

# Assign AcrPull role to AKS so it can pull images from ACR
resource "azurerm_role_assignment" "aks_acr_pull" {
  principal_id         = azurerm_kubernetes_cluster.bdcc.kubelet_identity[0].object_id
  role_definition_name = "AcrPull"
  scope               = azurerm_container_registry.acr.id
}

# Get Storage Account Key
data "azurerm_storage_account" "storage" {
  name                = azurerm_storage_account.bdcc.name
  resource_group_name = azurerm_resource_group.bdcc.name
}

resource "local_file" "azure_connector_config" {
  content = jsonencode({
    "name" = "expedia",
    "config" = {
      "connector.class"                   = "io.confluent.connect.azure.blob.storage.AzureBlobStorageSourceConnector"
      "azblob.account.name"               = azurerm_storage_account.bdcc.name
      "azblob.account.key"                = data.azurerm_storage_account.storage.primary_access_key
      "azblob.container.name"             = azurerm_storage_data_lake_gen2_filesystem.gen2_data.name
      "tasks.max"                         = "2"
      "format.class"                      = "io.confluent.connect.azure.blob.storage.format.avro.AvroFormat"
      "bootstrap.servers"                 = "kafka:9071"
      "topics"                            = "PUT_YOUR_TOPIC_NAME_HERE"
      "topics.dir"                        = "PUT_YOUR_DIR_NAME_WHERE_IS_TOPIC_LOCATED"
      // please add your MaskField configs here
    }
  })

  filename = "azure-source-cc.json"
}

output "storage_primary_access_key" {
  sensitive = true
  value     = data.azurerm_storage_account.storage.primary_access_key
}

output "client_certificate" {
  sensitive = true
  value = azurerm_kubernetes_cluster.bdcc.kube_config.0.client_certificate
}

output "aks_kubeconfig" {
  sensitive = true
  description = "The Kubernetes Kubeconfig file for AKS."
  value     = azurerm_kubernetes_cluster.bdcc.kube_config_raw
}

output "acr_login_server" {
  value       = azurerm_container_registry.acr.login_server
  description = "The login server of the Azure Container Registry."
}

output "aks_api_server_url" {
  sensitive = true
  description = "The Kubernetes API server endpoint for AKS."
  value       = azurerm_kubernetes_cluster.bdcc.kube_config.0.host
}

output "storage_account_name" {
  description = "The name of the created Azure Storage Account."
  value       = azurerm_storage_account.bdcc.name
}

output "resource_group_name" {
  description = "The name of the created Azure Resource Group."
  value       = azurerm_resource_group.bdcc.name
}

output "aks_name" {
  description = "The name of the AKS cluster"
  value       = azurerm_kubernetes_cluster.bdcc.name
}
