# Kafka Streams Homework

### Balázs Mikes

#### github link:
https://github.com/csirkepaprikas/M12_KafkaStreams_PYTHON_AZURE.git

This task is the second in a set of two tasks on streaming, and it focused on Kafka aspects and the Kafka Streams framework for implementing streaming solutions.
Through this assignment, I gained experience working with the Kafka Streams framework and became familiar with the enrichment process of data in streaming applications.
By the end of the task, I had practical skills in using Kafka Streams to implement streaming solutions and enrich streaming data, which are important skills for working with real-time data at scale.


## Preparations

First of all I created in the existing "base streaming" Resource Group a new container for the terraform:

![new_cont](https://github.com/user-attachments/assets/e5d75548-0d2c-4f3e-97f7-913440139bbd)

![created_cont](https://github.com/user-attachments/assets/4fe091f3-4d52-43c1-b71c-afbfbcc9d0d2)

Then I updated the terraform main.tf. and variables.tf files.
By the former I only inserted all the needed information about the Azure profile, but by the latter, I had to change the default location to "southafricanorth" because the "Standard_D3_v2" VM, which can handle the suffiecient disks in free tier available there instead of "westeurope".

The main.tf file:

```python
# Setup azurerm as a state backend
terraform {
  backend "azurerm" {
    resource_group_name  = "g"
    storage_account_name = "s" # Provide Storage Account name, where Terraform Remote state is stored
    container_name       = "tfstate"
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

```

The variables.tf file:

```python

variable "ENV" {
  type        = string
  description = "The prefix which should be used for all resources in this environment. Make it unique, like ksultanau."
  default = "dev"
}

variable "LOCATION" {
  type        = string
  description = "The Azure Region in which all resources in this example should be created."
  default     = "southafricanorth"
}

variable "BDCC_REGION" {
  type        = string
  description = "The BDCC Region for billing."
  default     = "global"
}

variable "STORAGE_ACCOUNT_REPLICATION_TYPE" {
  type        = string
  description = "Storage Account replication type."
  default     = "LRS"
}

variable "ACR_NAME" {
  type        = string
  description = "The name of the Azure Container Registry."
  default     = "" # Just provide a default static name or leave it empty.
}

variable "ACR_SKU" {
  type        = string
  description = "The SKU of the Azure Container Registry (e.g., Basic, Standard, Premium)."
  default     = "Standard"
}

variable "IP_RULES" {
  type        = map(string)
  description = "Map of IP addresses permitted to access"
  default = {
    "epam-vpn-ru-0" = "185.44.13.36"
    "epam-vpn-eu-0" = "195.56.119.209"
    "epam-vpn-eu-1" = "195.56.119.212"
    "epam-vpn-eu-2" = "204.153.55.4"
    "epam-vpn-in-0" = "203.170.48.2"
    "epam-vpn-ua-0" = "85.223.209.18"
    "epam-vpn-us-0" = "174.128.60.160"
    "epam-vpn-us-1" = "174.128.60.162"
    "epam-vpn-by-0" = "213.184.231.20"
    "epam-vpn-by-1" = "86.57.255.94"
  }
}
```

Then I continued with the deployment of the infrastructure with terraform. First I applied the "terraform init", then the "terraform plan" and finally the "terraform apply" commands.


