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

```python
c:\data_eng\házi\7\m12_kafkastreams_python_azure-master\terraform>terraform init
Initializing the backend...

Successfully configured the backend "azurerm"! Terraform will automatically
use this backend unless the backend configuration changes.
Initializing provider plugins...
- Finding latest version of hashicorp/random...
- Finding hashicorp/azurerm versions matching "~> 4.3.0"...
- Finding latest version of hashicorp/kubernetes...
- Finding latest version of hashicorp/local...
- Installing hashicorp/kubernetes v2.36.0...
- Installed hashicorp/kubernetes v2.36.0 (signed by HashiCorp)
- Installing hashicorp/local v2.5.2...
- Installed hashicorp/local v2.5.2 (signed by HashiCorp)
- Installing hashicorp/random v3.7.2...
- Installed hashicorp/random v3.7.2 (signed by HashiCorp)
- Installing hashicorp/azurerm v4.3.0...
- Installed hashicorp/azurerm v4.3.0 (signed by HashiCorp)
Terraform has created a lock file .terraform.lock.hcl to record the provider
selections it made above. Include this file in your version control repository
so that Terraform can guarantee to make the same selections by default when
you run "terraform init" in the future.

Terraform has been successfully initialized!

You may now begin working with Terraform. Try running "terraform plan" to see
any changes that are required for your infrastructure. All Terraform commands
should now work.

If you ever set or change modules or backend configuration for Terraform,
rerun this command to reinitialize your working directory. If you forget, other
commands will detect it and remind you to do so if necessary.

c:\data_eng\házi\7\m12_kafkastreams_python_azure-master\terraform>terraform plan
Acquiring state lock. This may take a few moments...
data.azurerm_client_config.current: Reading...
data.azurerm_client_config.current: Read complete after 0s [id==]

Terraform used the selected providers to generate the following execution plan. Resource actions are indicated with the following symbols:
  + create
 <= read (data resources)

Terraform will perform the following actions:

  # data.azurerm_storage_account.storage will be read during apply
  # (config refers to values not yet known)
 <= data "azurerm_storage_account" "storage" {
      + access_tier                        = (known after apply)
      + account_kind                       = (known after apply)
      + account_replication_type           = (known after apply)
      + account_tier                       = (known after apply)
      + allow_nested_items_to_be_public    = (known after apply)
      + azure_files_authentication         = (known after apply)
      + custom_domain                      = (known after apply)
      + dns_endpoint_type                  = (known after apply)
      + https_traffic_only_enabled         = (known after apply)
      + id                                 = (known after apply)
      + identity                           = (known after apply)
      + infrastructure_encryption_enabled  = (known after apply)
      + is_hns_enabled                     = (known after apply)
      + location                           = (known after apply)
      + name                               = (known after apply)
      + nfsv3_enabled                      = (known after apply)
      + primary_access_key                 = (sensitive value)
      + primary_blob_connection_string     = (sensitive value)
      + primary_blob_endpoint              = (known after apply)
      + primary_blob_host                  = (known after apply)
      + primary_blob_internet_endpoint     = (known after apply)
      + primary_blob_internet_host         = (known after apply)
      + primary_blob_microsoft_endpoint    = (known after apply)
      + primary_blob_microsoft_host        = (known after apply)
      + primary_connection_string          = (sensitive value)
      + primary_dfs_endpoint               = (known after apply)
      + primary_dfs_host                   = (known after apply)
      + primary_dfs_internet_endpoint      = (known after apply)
      + primary_dfs_internet_host          = (known after apply)
      + primary_dfs_microsoft_endpoint     = (known after apply)
      + primary_dfs_microsoft_host         = (known after apply)
      + primary_file_endpoint              = (known after apply)
      + primary_file_host                  = (known after apply)
      + primary_file_internet_endpoint     = (known after apply)
      + primary_file_internet_host         = (known after apply)
      + primary_file_microsoft_endpoint    = (known after apply)
      + primary_file_microsoft_host        = (known after apply)
      + primary_location                   = (known after apply)
      + primary_queue_endpoint             = (known after apply)
      + primary_queue_host                 = (known after apply)
      + primary_queue_microsoft_endpoint   = (known after apply)
      + primary_queue_microsoft_host       = (known after apply)
      + primary_table_endpoint             = (known after apply)
      + primary_table_host                 = (known after apply)
      + primary_table_microsoft_endpoint   = (known after apply)
      + primary_table_microsoft_host       = (known after apply)
      + primary_web_endpoint               = (known after apply)
      + primary_web_host                   = (known after apply)
      + primary_web_internet_endpoint      = (known after apply)
      + primary_web_internet_host          = (known after apply)
      + primary_web_microsoft_endpoint     = (known after apply)
      + primary_web_microsoft_host         = (known after apply)
      + queue_encryption_key_type          = (known after apply)
      + resource_group_name                = (known after apply)
      + secondary_access_key               = (sensitive value)
      + secondary_blob_connection_string   = (sensitive value)
      + secondary_blob_endpoint            = (known after apply)
      + secondary_blob_host                = (known after apply)
      + secondary_blob_internet_endpoint   = (known after apply)
      + secondary_blob_internet_host       = (known after apply)
      + secondary_blob_microsoft_endpoint  = (known after apply)
      + secondary_blob_microsoft_host      = (known after apply)
      + secondary_connection_string        = (sensitive value)
      + secondary_dfs_endpoint             = (known after apply)
      + secondary_dfs_host                 = (known after apply)
      + secondary_dfs_internet_endpoint    = (known after apply)
      + secondary_dfs_internet_host        = (known after apply)
      + secondary_dfs_microsoft_endpoint   = (known after apply)
      + secondary_dfs_microsoft_host       = (known after apply)
      + secondary_file_endpoint            = (known after apply)
      + secondary_file_host                = (known after apply)
      + secondary_file_internet_endpoint   = (known after apply)
      + secondary_file_internet_host       = (known after apply)
      + secondary_file_microsoft_endpoint  = (known after apply)
      + secondary_file_microsoft_host      = (known after apply)
      + secondary_location                 = (known after apply)
      + secondary_queue_endpoint           = (known after apply)
      + secondary_queue_host               = (known after apply)
      + secondary_queue_microsoft_endpoint = (known after apply)
      + secondary_queue_microsoft_host     = (known after apply)
      + secondary_table_endpoint           = (known after apply)
      + secondary_table_host               = (known after apply)
      + secondary_table_microsoft_endpoint = (known after apply)
      + secondary_table_microsoft_host     = (known after apply)
      + secondary_web_endpoint             = (known after apply)
      + secondary_web_host                 = (known after apply)
      + secondary_web_internet_endpoint    = (known after apply)
      + secondary_web_internet_host        = (known after apply)
      + secondary_web_microsoft_endpoint   = (known after apply)
      + secondary_web_microsoft_host       = (known after apply)
      + table_encryption_key_type          = (known after apply)
      + tags                               = (known after apply)
    }

  # azurerm_container_registry.acr will be created
  + resource "azurerm_container_registry" "acr" {
      + admin_enabled                 = false
      + admin_password                = (sensitive value)
      + admin_username                = (known after apply)
      + encryption                    = (known after apply)
      + export_policy_enabled         = true
      + id                            = (known after apply)
      + location                      = "southafricanorth"
      + login_server                  = (known after apply)
      + name                          = (known after apply)
      + network_rule_bypass_option    = "AzureServices"
      + network_rule_set              = (known after apply)
      + public_network_access_enabled = true
      + resource_group_name           = (known after apply)
      + sku                           = "Standard"
      + tags                          = {
          + "env"    = "dev"
          + "region" = "global"
        }
      + trust_policy_enabled          = false
      + zone_redundancy_enabled       = false
    }

  # azurerm_kubernetes_cluster.bdcc will be created
  + resource "azurerm_kubernetes_cluster" "bdcc" {
      + current_kubernetes_version          = (known after apply)
      + dns_prefix                          = "bdccdev"
      + fqdn                                = (known after apply)
      + http_application_routing_zone_name  = (known after apply)
      + id                                  = (known after apply)
      + kube_admin_config                   = (sensitive value)
      + kube_admin_config_raw               = (sensitive value)
      + kube_config                         = (sensitive value)
      + kube_config_raw                     = (sensitive value)
      + kubernetes_version                  = (known after apply)
      + location                            = "southafricanorth"
      + name                                = (known after apply)
      + node_os_upgrade_channel             = "NodeImage"
      + node_resource_group                 = (known after apply)
      + node_resource_group_id              = (known after apply)
      + oidc_issuer_url                     = (known after apply)
      + portal_fqdn                         = (known after apply)
      + private_cluster_enabled             = false
      + private_cluster_public_fqdn_enabled = false
      + private_dns_zone_id                 = (known after apply)
      + private_fqdn                        = (known after apply)
      + resource_group_name                 = (known after apply)
      + role_based_access_control_enabled   = true
      + run_command_enabled                 = true
      + sku_tier                            = "Free"
      + support_plan                        = "KubernetesOfficial"
      + tags                                = {
          + "env"    = "dev"
          + "region" = "global"
        }
      + workload_identity_enabled           = false

      + auto_scaler_profile (known after apply)

      + default_node_pool {
          + kubelet_disk_type    = (known after apply)
          + max_pods             = (known after apply)
          + name                 = "default"
          + node_count           = 1
          + node_labels          = (known after apply)
          + orchestrator_version = (known after apply)
          + os_disk_size_gb      = (known after apply)
          + os_disk_type         = "Managed"
          + os_sku               = (known after apply)
          + scale_down_mode      = "Delete"
          + type                 = "VirtualMachineScaleSets"
          + ultra_ssd_enabled    = false
          + vm_size              = "Standard_D3_v2"
          + workload_runtime     = (known after apply)
        }

      + identity {
          + principal_id = (known after apply)
          + tenant_id    = (known after apply)
          + type         = "SystemAssigned"
        }

      + kubelet_identity (known after apply)

      + network_profile (known after apply)

      + windows_profile (known after apply)
    }

  # azurerm_resource_group.bdcc will be created
  + resource "azurerm_resource_group" "bdcc" {
      + id       = (known after apply)
      + location = "southafricanorth"
      + name     = (known after apply)
      + tags     = {
          + "env"    = "dev"
          + "region" = "global"
        }
    }

  # azurerm_role_assignment.aks_acr_pull will be created
  + resource "azurerm_role_assignment" "aks_acr_pull" {
      + id                               = (known after apply)
      + name                             = (known after apply)
      + principal_id                     = (known after apply)
      + principal_type                   = (known after apply)
      + role_definition_id               = (known after apply)
      + role_definition_name             = "AcrPull"
      + scope                            = (known after apply)
      + skip_service_principal_aad_check = (known after apply)
    }

  # azurerm_storage_account.bdcc will be created
  + resource "azurerm_storage_account" "bdcc" {
      + access_tier                        = (known after apply)
      + account_kind                       = "StorageV2"
      + account_replication_type           = "LRS"
      + account_tier                       = "Standard"
      + allow_nested_items_to_be_public    = true
      + cross_tenant_replication_enabled   = false
      + default_to_oauth_authentication    = false
      + dns_endpoint_type                  = "Standard"
      + https_traffic_only_enabled         = true
      + id                                 = (known after apply)
      + infrastructure_encryption_enabled  = false
      + is_hns_enabled                     = true
      + large_file_share_enabled           = (known after apply)
      + local_user_enabled                 = true
      + location                           = "southafricanorth"
      + min_tls_version                    = "TLS1_2"
      + name                               = (known after apply)
      + nfsv3_enabled                      = false
      + primary_access_key                 = (sensitive value)
      + primary_blob_connection_string     = (sensitive value)
      + primary_blob_endpoint              = (known after apply)
      + primary_blob_host                  = (known after apply)
      + primary_blob_internet_endpoint     = (known after apply)
      + primary_blob_internet_host         = (known after apply)
      + primary_blob_microsoft_endpoint    = (known after apply)
      + primary_blob_microsoft_host        = (known after apply)
      + primary_connection_string          = (sensitive value)
      + primary_dfs_endpoint               = (known after apply)
      + primary_dfs_host                   = (known after apply)
      + primary_dfs_internet_endpoint      = (known after apply)
      + primary_dfs_internet_host          = (known after apply)
      + primary_dfs_microsoft_endpoint     = (known after apply)
      + primary_dfs_microsoft_host         = (known after apply)
      + primary_file_endpoint              = (known after apply)
      + primary_file_host                  = (known after apply)
      + primary_file_internet_endpoint     = (known after apply)
      + primary_file_internet_host         = (known after apply)
      + primary_file_microsoft_endpoint    = (known after apply)
      + primary_file_microsoft_host        = (known after apply)
      + primary_location                   = (known after apply)
      + primary_queue_endpoint             = (known after apply)
      + primary_queue_host                 = (known after apply)
      + primary_queue_microsoft_endpoint   = (known after apply)
      + primary_queue_microsoft_host       = (known after apply)
      + primary_table_endpoint             = (known after apply)
      + primary_table_host                 = (known after apply)
      + primary_table_microsoft_endpoint   = (known after apply)
      + primary_table_microsoft_host       = (known after apply)
      + primary_web_endpoint               = (known after apply)
      + primary_web_host                   = (known after apply)
      + primary_web_internet_endpoint      = (known after apply)
      + primary_web_internet_host          = (known after apply)
      + primary_web_microsoft_endpoint     = (known after apply)
      + primary_web_microsoft_host         = (known after apply)
      + public_network_access_enabled      = true
      + queue_encryption_key_type          = "Service"
      + resource_group_name                = (known after apply)
      + secondary_access_key               = (sensitive value)
      + secondary_blob_connection_string   = (sensitive value)
      + secondary_blob_endpoint            = (known after apply)
      + secondary_blob_host                = (known after apply)
      + secondary_blob_internet_endpoint   = (known after apply)
      + secondary_blob_internet_host       = (known after apply)
      + secondary_blob_microsoft_endpoint  = (known after apply)
      + secondary_blob_microsoft_host      = (known after apply)
      + secondary_connection_string        = (sensitive value)
      + secondary_dfs_endpoint             = (known after apply)
      + secondary_dfs_host                 = (known after apply)
      + secondary_dfs_internet_endpoint    = (known after apply)
      + secondary_dfs_internet_host        = (known after apply)
      + secondary_dfs_microsoft_endpoint   = (known after apply)
      + secondary_dfs_microsoft_host       = (known after apply)
      + secondary_file_endpoint            = (known after apply)
      + secondary_file_host                = (known after apply)
      + secondary_file_internet_endpoint   = (known after apply)
      + secondary_file_internet_host       = (known after apply)
      + secondary_file_microsoft_endpoint  = (known after apply)
      + secondary_file_microsoft_host      = (known after apply)
      + secondary_location                 = (known after apply)
      + secondary_queue_endpoint           = (known after apply)
      + secondary_queue_host               = (known after apply)
      + secondary_queue_microsoft_endpoint = (known after apply)
      + secondary_queue_microsoft_host     = (known after apply)
      + secondary_table_endpoint           = (known after apply)
      + secondary_table_host               = (known after apply)
      + secondary_table_microsoft_endpoint = (known after apply)
      + secondary_table_microsoft_host     = (known after apply)
      + secondary_web_endpoint             = (known after apply)
      + secondary_web_host                 = (known after apply)
      + secondary_web_internet_endpoint    = (known after apply)
      + secondary_web_internet_host        = (known after apply)
      + secondary_web_microsoft_endpoint   = (known after apply)
      + secondary_web_microsoft_host       = (known after apply)
      + sftp_enabled                       = false
      + shared_access_key_enabled          = true
      + table_encryption_key_type          = "Service"
      + tags                               = {
          + "env"    = "dev"
          + "region" = "global"
        }

      + blob_properties (known after apply)

      + network_rules {
          + bypass                     = (known after apply)
          + default_action             = "Allow"
          + ip_rules                   = [
              + "174.128.60.160",
              + "174.128.60.162",
              + "185.44.13.36",
              + "195.56.119.209",
              + "195.56.119.212",
              + "203.170.48.2",
              + "204.153.55.4",
              + "213.184.231.20",
              + "85.223.209.18",
              + "86.57.255.94",
            ]
          + virtual_network_subnet_ids = (known after apply)
        }

      + queue_properties (known after apply)

      + routing (known after apply)

      + share_properties (known after apply)
    }

  # azurerm_storage_data_lake_gen2_filesystem.gen2_data will be created
  + resource "azurerm_storage_data_lake_gen2_filesystem" "gen2_data" {
      + default_encryption_scope = (known after apply)
      + group                    = (known after apply)
      + id                       = (known after apply)
      + name                     = "data"
      + owner                    = (known after apply)
      + storage_account_id       = (known after apply)

      + ace (known after apply)
    }

  # kubernetes_namespace.confluent will be created
  + resource "kubernetes_namespace" "confluent" {
      + id                               = (known after apply)
      + wait_for_default_service_account = false

      + metadata {
          + generation       = (known after apply)
          + name             = "confluent"
          + resource_version = (known after apply)
          + uid              = (known after apply)
        }
    }

  # local_file.azure_connector_config will be created
  + resource "local_file" "azure_connector_config" {
      + content              = (sensitive value)
      + content_base64sha256 = (known after apply)
      + content_base64sha512 = (known after apply)
      + content_md5          = (known after apply)
      + content_sha1         = (known after apply)
      + content_sha256       = (known after apply)
      + content_sha512       = (known after apply)
      + directory_permission = "0777"
      + file_permission      = "0777"
      + filename             = "azure-source-cc.json"
      + id                   = (known after apply)
    }

  # random_string.suffix will be created
  + resource "random_string" "suffix" {
      + id          = (known after apply)
      + length      = 2
      + lower       = true
      + min_lower   = 0
      + min_numeric = 0
      + min_special = 0
      + min_upper   = 0
      + number      = true
      + numeric     = true
      + result      = (known after apply)
      + special     = false
      + upper       = false
    }

Plan: 9 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + acr_login_server           = (known after apply)
  + aks_api_server_url         = (sensitive value)
  + aks_kubeconfig             = (sensitive value)
  + aks_name                   = (known after apply)
  + client_certificate         = (sensitive value)
  + resource_group_name        = (known after apply)
  + storage_account_name       = (known after apply)
  + storage_primary_access_key = (sensitive value)

───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so Terraform can't guarantee to take exactly these actions if you run "terraform apply" now.
Releasing state lock. This may take a few moments...

c:\data_eng\házi\7\m12_kafkastreams_python_azure-master\terraform>terraform apply
Acquiring state lock. This may take a few moments...
data.azurerm_client_config.current: Reading...
data.azurerm_client_config.current: Read complete after 0s [id=I=]

Terraform used the selected providers to generate the following execution plan. Resource actions are indicated with the following symbols:
  + create
 <= read (data resources)

Terraform will perform the following actions:

  # data.azurerm_storage_account.storage will be read during apply
  # (config refers to values not yet known)
 <= data "azurerm_storage_account" "storage" {
      + access_tier                        = (known after apply)
      + account_kind                       = (known after apply)
      + account_replication_type           = (known after apply)
      + account_tier                       = (known after apply)
      + allow_nested_items_to_be_public    = (known after apply)
      + azure_files_authentication         = (known after apply)
      + custom_domain                      = (known after apply)
      + dns_endpoint_type                  = (known after apply)
      + https_traffic_only_enabled         = (known after apply)
      + id                                 = (known after apply)
      + identity                           = (known after apply)
      + infrastructure_encryption_enabled  = (known after apply)
      + is_hns_enabled                     = (known after apply)
      + location                           = (known after apply)
      + name                               = (known after apply)
      + nfsv3_enabled                      = (known after apply)
      + primary_access_key                 = (sensitive value)
      + primary_blob_connection_string     = (sensitive value)
      + primary_blob_endpoint              = (known after apply)
      + primary_blob_host                  = (known after apply)
      + primary_blob_internet_endpoint     = (known after apply)
      + primary_blob_internet_host         = (known after apply)
      + primary_blob_microsoft_endpoint    = (known after apply)
      + primary_blob_microsoft_host        = (known after apply)
      + primary_connection_string          = (sensitive value)
      + primary_dfs_endpoint               = (known after apply)
      + primary_dfs_host                   = (known after apply)
      + primary_dfs_internet_endpoint      = (known after apply)
      + primary_dfs_internet_host          = (known after apply)
      + primary_dfs_microsoft_endpoint     = (known after apply)
      + primary_dfs_microsoft_host         = (known after apply)
      + primary_file_endpoint              = (known after apply)
      + primary_file_host                  = (known after apply)
      + primary_file_internet_endpoint     = (known after apply)
      + primary_file_internet_host         = (known after apply)
      + primary_file_microsoft_endpoint    = (known after apply)
      + primary_file_microsoft_host        = (known after apply)
      + primary_location                   = (known after apply)
      + primary_queue_endpoint             = (known after apply)
      + primary_queue_host                 = (known after apply)
      + primary_queue_microsoft_endpoint   = (known after apply)
      + primary_queue_microsoft_host       = (known after apply)
      + primary_table_endpoint             = (known after apply)
      + primary_table_host                 = (known after apply)
      + primary_table_microsoft_endpoint   = (known after apply)
      + primary_table_microsoft_host       = (known after apply)
      + primary_web_endpoint               = (known after apply)
      + primary_web_host                   = (known after apply)
      + primary_web_internet_endpoint      = (known after apply)
      + primary_web_internet_host          = (known after apply)
      + primary_web_microsoft_endpoint     = (known after apply)
      + primary_web_microsoft_host         = (known after apply)
      + queue_encryption_key_type          = (known after apply)
      + resource_group_name                = (known after apply)
      + secondary_access_key               = (sensitive value)
      + secondary_blob_connection_string   = (sensitive value)
      + secondary_blob_endpoint            = (known after apply)
      + secondary_blob_host                = (known after apply)
      + secondary_blob_internet_endpoint   = (known after apply)
      + secondary_blob_internet_host       = (known after apply)
      + secondary_blob_microsoft_endpoint  = (known after apply)
      + secondary_blob_microsoft_host      = (known after apply)
      + secondary_connection_string        = (sensitive value)
      + secondary_dfs_endpoint             = (known after apply)
      + secondary_dfs_host                 = (known after apply)
      + secondary_dfs_internet_endpoint    = (known after apply)
      + secondary_dfs_internet_host        = (known after apply)
      + secondary_dfs_microsoft_endpoint   = (known after apply)
      + secondary_dfs_microsoft_host       = (known after apply)
      + secondary_file_endpoint            = (known after apply)
      + secondary_file_host                = (known after apply)
      + secondary_file_internet_endpoint   = (known after apply)
      + secondary_file_internet_host       = (known after apply)
      + secondary_file_microsoft_endpoint  = (known after apply)
      + secondary_file_microsoft_host      = (known after apply)
      + secondary_location                 = (known after apply)
      + secondary_queue_endpoint           = (known after apply)
      + secondary_queue_host               = (known after apply)
      + secondary_queue_microsoft_endpoint = (known after apply)
      + secondary_queue_microsoft_host     = (known after apply)
      + secondary_table_endpoint           = (known after apply)
      + secondary_table_host               = (known after apply)
      + secondary_table_microsoft_endpoint = (known after apply)
      + secondary_table_microsoft_host     = (known after apply)
      + secondary_web_endpoint             = (known after apply)
      + secondary_web_host                 = (known after apply)
      + secondary_web_internet_endpoint    = (known after apply)
      + secondary_web_internet_host        = (known after apply)
      + secondary_web_microsoft_endpoint   = (known after apply)
      + secondary_web_microsoft_host       = (known after apply)
      + table_encryption_key_type          = (known after apply)
      + tags                               = (known after apply)
    }

  # azurerm_container_registry.acr will be created
  + resource "azurerm_container_registry" "acr" {
      + admin_enabled                 = false
      + admin_password                = (sensitive value)
      + admin_username                = (known after apply)
      + encryption                    = (known after apply)
      + export_policy_enabled         = true
      + id                            = (known after apply)
      + location                      = "southafricanorth"
      + login_server                  = (known after apply)
      + name                          = (known after apply)
      + network_rule_bypass_option    = "AzureServices"
      + network_rule_set              = (known after apply)
      + public_network_access_enabled = true
      + resource_group_name           = (known after apply)
      + sku                           = "Standard"
      + tags                          = {
          + "env"    = "dev"
          + "region" = "global"
        }
      + trust_policy_enabled          = false
      + zone_redundancy_enabled       = false
    }

  # azurerm_kubernetes_cluster.bdcc will be created
  + resource "azurerm_kubernetes_cluster" "bdcc" {
      + current_kubernetes_version          = (known after apply)
      + dns_prefix                          = "bdccdev"
      + fqdn                                = (known after apply)
      + http_application_routing_zone_name  = (known after apply)
      + id                                  = (known after apply)
      + kube_admin_config                   = (sensitive value)
      + kube_admin_config_raw               = (sensitive value)
      + kube_config                         = (sensitive value)
      + kube_config_raw                     = (sensitive value)
      + kubernetes_version                  = (known after apply)
      + location                            = "southafricanorth"
      + name                                = (known after apply)
      + node_os_upgrade_channel             = "NodeImage"
      + node_resource_group                 = (known after apply)
      + node_resource_group_id              = (known after apply)
      + oidc_issuer_url                     = (known after apply)
      + portal_fqdn                         = (known after apply)
      + private_cluster_enabled             = false
      + private_cluster_public_fqdn_enabled = false
      + private_dns_zone_id                 = (known after apply)
      + private_fqdn                        = (known after apply)
      + resource_group_name                 = (known after apply)
      + role_based_access_control_enabled   = true
      + run_command_enabled                 = true
      + sku_tier                            = "Free"
      + support_plan                        = "KubernetesOfficial"
      + tags                                = {
          + "env"    = "dev"
          + "region" = "global"
        }
      + workload_identity_enabled           = false

      + auto_scaler_profile (known after apply)

      + default_node_pool {
          + kubelet_disk_type    = (known after apply)
          + max_pods             = (known after apply)
          + name                 = "default"
          + node_count           = 1
          + node_labels          = (known after apply)
          + orchestrator_version = (known after apply)
          + os_disk_size_gb      = (known after apply)
          + os_disk_type         = "Managed"
          + os_sku               = (known after apply)
          + scale_down_mode      = "Delete"
          + type                 = "VirtualMachineScaleSets"
          + ultra_ssd_enabled    = false
          + vm_size              = "Standard_D3_v2"
          + workload_runtime     = (known after apply)
        }

      + identity {
          + principal_id = (known after apply)
          + tenant_id    = (known after apply)
          + type         = "SystemAssigned"
        }

      + kubelet_identity (known after apply)

      + network_profile (known after apply)

      + windows_profile (known after apply)
    }

  # azurerm_resource_group.bdcc will be created
  + resource "azurerm_resource_group" "bdcc" {
      + id       = (known after apply)
      + location = "southafricanorth"
      + name     = (known after apply)
      + tags     = {
          + "env"    = "dev"
          + "region" = "global"
        }
    }

  # azurerm_role_assignment.aks_acr_pull will be created
  + resource "azurerm_role_assignment" "aks_acr_pull" {
      + id                               = (known after apply)
      + name                             = (known after apply)
      + principal_id                     = (known after apply)
      + principal_type                   = (known after apply)
      + role_definition_id               = (known after apply)
      + role_definition_name             = "AcrPull"
      + scope                            = (known after apply)
      + skip_service_principal_aad_check = (known after apply)
    }

  # azurerm_storage_account.bdcc will be created
  + resource "azurerm_storage_account" "bdcc" {
      + access_tier                        = (known after apply)
      + account_kind                       = "StorageV2"
      + account_replication_type           = "LRS"
      + account_tier                       = "Standard"
      + allow_nested_items_to_be_public    = true
      + cross_tenant_replication_enabled   = false
      + default_to_oauth_authentication    = false
      + dns_endpoint_type                  = "Standard"
      + https_traffic_only_enabled         = true
      + id                                 = (known after apply)
      + infrastructure_encryption_enabled  = false
      + is_hns_enabled                     = true
      + large_file_share_enabled           = (known after apply)
      + local_user_enabled                 = true
      + location                           = "southafricanorth"
      + min_tls_version                    = "TLS1_2"
      + name                               = (known after apply)
      + nfsv3_enabled                      = false
      + primary_access_key                 = (sensitive value)
      + primary_blob_connection_string     = (sensitive value)
      + primary_blob_endpoint              = (known after apply)
      + primary_blob_host                  = (known after apply)
      + primary_blob_internet_endpoint     = (known after apply)
      + primary_blob_internet_host         = (known after apply)
      + primary_blob_microsoft_endpoint    = (known after apply)
      + primary_blob_microsoft_host        = (known after apply)
      + primary_connection_string          = (sensitive value)
      + primary_dfs_endpoint               = (known after apply)
      + primary_dfs_host                   = (known after apply)
      + primary_dfs_internet_endpoint      = (known after apply)
      + primary_dfs_internet_host          = (known after apply)
      + primary_dfs_microsoft_endpoint     = (known after apply)
      + primary_dfs_microsoft_host         = (known after apply)
      + primary_file_endpoint              = (known after apply)
      + primary_file_host                  = (known after apply)
      + primary_file_internet_endpoint     = (known after apply)
      + primary_file_internet_host         = (known after apply)
      + primary_file_microsoft_endpoint    = (known after apply)
      + primary_file_microsoft_host        = (known after apply)
      + primary_location                   = (known after apply)
      + primary_queue_endpoint             = (known after apply)
      + primary_queue_host                 = (known after apply)
      + primary_queue_microsoft_endpoint   = (known after apply)
      + primary_queue_microsoft_host       = (known after apply)
      + primary_table_endpoint             = (known after apply)
      + primary_table_host                 = (known after apply)
      + primary_table_microsoft_endpoint   = (known after apply)
      + primary_table_microsoft_host       = (known after apply)
      + primary_web_endpoint               = (known after apply)
      + primary_web_host                   = (known after apply)
      + primary_web_internet_endpoint      = (known after apply)
      + primary_web_internet_host          = (known after apply)
      + primary_web_microsoft_endpoint     = (known after apply)
      + primary_web_microsoft_host         = (known after apply)
      + public_network_access_enabled      = true
      + queue_encryption_key_type          = "Service"
      + resource_group_name                = (known after apply)
      + secondary_access_key               = (sensitive value)
      + secondary_blob_connection_string   = (sensitive value)
      + secondary_blob_endpoint            = (known after apply)
      + secondary_blob_host                = (known after apply)
      + secondary_blob_internet_endpoint   = (known after apply)
      + secondary_blob_internet_host       = (known after apply)
      + secondary_blob_microsoft_endpoint  = (known after apply)
      + secondary_blob_microsoft_host      = (known after apply)
      + secondary_connection_string        = (sensitive value)
      + secondary_dfs_endpoint             = (known after apply)
      + secondary_dfs_host                 = (known after apply)
      + secondary_dfs_internet_endpoint    = (known after apply)
      + secondary_dfs_internet_host        = (known after apply)
      + secondary_dfs_microsoft_endpoint   = (known after apply)
      + secondary_dfs_microsoft_host       = (known after apply)
      + secondary_file_endpoint            = (known after apply)
      + secondary_file_host                = (known after apply)
      + secondary_file_internet_endpoint   = (known after apply)
      + secondary_file_internet_host       = (known after apply)
      + secondary_file_microsoft_endpoint  = (known after apply)
      + secondary_file_microsoft_host      = (known after apply)
      + secondary_location                 = (known after apply)
      + secondary_queue_endpoint           = (known after apply)
      + secondary_queue_host               = (known after apply)
      + secondary_queue_microsoft_endpoint = (known after apply)
      + secondary_queue_microsoft_host     = (known after apply)
      + secondary_table_endpoint           = (known after apply)
      + secondary_table_host               = (known after apply)
      + secondary_table_microsoft_endpoint = (known after apply)
      + secondary_table_microsoft_host     = (known after apply)
      + secondary_web_endpoint             = (known after apply)
      + secondary_web_host                 = (known after apply)
      + secondary_web_internet_endpoint    = (known after apply)
      + secondary_web_internet_host        = (known after apply)
      + secondary_web_microsoft_endpoint   = (known after apply)
      + secondary_web_microsoft_host       = (known after apply)
      + sftp_enabled                       = false
      + shared_access_key_enabled          = true
      + table_encryption_key_type          = "Service"
      + tags                               = {
          + "env"    = "dev"
          + "region" = "global"
        }

      + blob_properties (known after apply)

      + network_rules {
          + bypass                     = (known after apply)
          + default_action             = "Allow"
          + ip_rules                   = [
              + "174.128.60.160",
              + "174.128.60.162",
              + "185.44.13.36",
              + "195.56.119.209",
              + "195.56.119.212",
              + "203.170.48.2",
              + "204.153.55.4",
              + "213.184.231.20",
              + "85.223.209.18",
              + "86.57.255.94",
            ]
          + virtual_network_subnet_ids = (known after apply)
        }

      + queue_properties (known after apply)

      + routing (known after apply)

      + share_properties (known after apply)
    }

  # azurerm_storage_data_lake_gen2_filesystem.gen2_data will be created
  + resource "azurerm_storage_data_lake_gen2_filesystem" "gen2_data" {
      + default_encryption_scope = (known after apply)
      + group                    = (known after apply)
      + id                       = (known after apply)
      + name                     = "data"
      + owner                    = (known after apply)
      + storage_account_id       = (known after apply)

      + ace (known after apply)
    }

  # kubernetes_namespace.confluent will be created
  + resource "kubernetes_namespace" "confluent" {
      + id                               = (known after apply)
      + wait_for_default_service_account = false

      + metadata {
          + generation       = (known after apply)
          + name             = "confluent"
          + resource_version = (known after apply)
          + uid              = (known after apply)
        }
    }

  # local_file.azure_connector_config will be created
  + resource "local_file" "azure_connector_config" {
      + content              = (sensitive value)
      + content_base64sha256 = (known after apply)
      + content_base64sha512 = (known after apply)
      + content_md5          = (known after apply)
      + content_sha1         = (known after apply)
      + content_sha256       = (known after apply)
      + content_sha512       = (known after apply)
      + directory_permission = "0777"
      + file_permission      = "0777"
      + filename             = "azure-source-cc.json"
      + id                   = (known after apply)
    }

  # random_string.suffix will be created
  + resource "random_string" "suffix" {
      + id          = (known after apply)
      + length      = 2
      + lower       = true
      + min_lower   = 0
      + min_numeric = 0
      + min_special = 0
      + min_upper   = 0
      + number      = true
      + numeric     = true
      + result      = (known after apply)
      + special     = false
      + upper       = false
    }

Plan: 9 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + acr_login_server           = (known after apply)
  + aks_api_server_url         = (sensitive value)
  + aks_kubeconfig             = (sensitive value)
  + aks_name                   = (known after apply)
  + client_certificate         = (sensitive value)
  + resource_group_name        = (known after apply)
  + storage_account_name       = (known after apply)
  + storage_primary_access_key = (sensitive value)

Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes

random_string.suffix: Creating...
random_string.suffix: Creation complete after 0s [id=ld]
azurerm_resource_group.bdcc: Creating...
azurerm_resource_group.bdcc: Creation complete after 10s [id=/subscriptions/1]
azurerm_container_registry.acr: Creating...
azurerm_storage_account.bdcc: Creating...
azurerm_kubernetes_cluster.bdcc: Creating...
azurerm_container_registry.acr: Still creating... [10s elapsed]
azurerm_storage_account.bdcc: Still creating... [10s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [10s elapsed]
azurerm_container_registry.acr: Still creating... [20s elapsed]
azurerm_storage_account.bdcc: Still creating... [20s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [20s elapsed]
azurerm_container_registry.acr: Creation complete after 28s [id=/subscriptions//providers/Microsoft.ContainerRegistry/registries
azurerm_storage_account.bdcc: Still creating... [30s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [30s elapsed]
azurerm_storage_account.bdcc: Still creating... [40s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [40s elapsed]
azurerm_storage_account.bdcc: Still creating... [50s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [50s elapsed]
azurerm_storage_account.bdcc: Still creating... [1m0s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [1m0s elapsed]
azurerm_storage_account.bdcc: Still creating... [1m10s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [1m10s elapsed]
azurerm_storage_account.bdcc: Still creating... [1m20s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [1m20s elapsed]
azurerm_storage_account.bdcc: Creation complete after 1m20s [id=/subscriptions/1r]
data.azurerm_storage_account.storage: Reading...
azurerm_storage_data_lake_gen2_filesystem.gen2_data: Creating...
data.azurerm_storage_account.storage: Read complete after 2s [id=/subscriptions/
azurerm_storage_data_lake_gen2_filesystem.gen2_data: Creation complete after 4s [i]
local_file.azure_connector_config: Creating...
local_file.azure_connector_config: Creation complete after 0s [id=ded]
azurerm_kubernetes_cluster.bdcc: Still creating... [1m30s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [1m40s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [1m50s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [2m0s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [2m10s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [2m20s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [2m30s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [2m40s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [2m50s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [3m0s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [3m10s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [3m20s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [3m30s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [3m40s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [3m50s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [4m0s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [4m10s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [4m20s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [4m30s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [4m40s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [4m50s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [5m0s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [5m10s elapsed]
azurerm_kubernetes_cluster.bdcc: Still creating... [5m20s elapsed]
azurerm_kubernetes_cluster.bdcc: Creation complete after 5m22s [id=/subscriptions/d]
azurerm_role_assignment.aks_acr_pull: Creating...
kubernetes_namespace.confluent: Creating...
kubernetes_namespace.confluent: Creation complete after 1s [id=confluent]
azurerm_role_assignment.aks_acr_pull: Still creating... [10s elapsed]
azurerm_role_assignment.aks_acr_pull: Still creating... [20s elapsed]
azurerm_role_assignment.aks_acr_pull: Creation complete after 27s [id=/subscriptions/1a
Releasing state lock. This may take a few moments...

Apply complete! Resources: 9 added, 0 changed, 0 destroyed.

Outputs:

acr_login_server = ""
aks_api_server_url = <sensitive>
aks_kubeconfig = <sensitive>
aks_name = ""
client_certificate = <sensitive>
resource_group_name = ""
storage_account_name = "dd"
storage_primary_access_key = <sensitive>

c:\data_eng\házi\7\m12_kafkastreams_python_azure-master\terraform>
```

Also checked zhe resources in the Azure portal:

![new_RGs](https://github.com/user-attachments/assets/cd9ffe07-d9db-4042-adf2-eaa6d9ffef2d)

![rd_dev_ins](https://github.com/user-attachments/assets/3fffde42-78ca-43ac-986a-b1d5265958af)

Also the "azure-source-cc.json" was created successfully.

### Retrieve kubeconfig.yaml and Set It as Default:

Set kubeconfig.yaml as Default for kubectl in Current Terminal Session:

```phyton
Merged "aks-dev-" as current context in C:\Users\mikes\.kube\config
```
Switched to the project kubernetes namespace:
  
```phyton
c:\data_eng\házi\7\m12_kafkastreams_python_azure-master\terraform>kubectl config set-context --current --namespace confluent
Context "aks-" modified.
```

Then verified the Kubernetes Cluster Connectivity:
    
  ```phyton
c:\data_eng\házi\7\m12_kafkastreams_python_azure-master\terraform>kubectl get nodes
    NAME                              STATUS   ROLES    AGE    VERSION
    aks-default-18464414-vmss000000   Ready    <none>   121m   v1.31.7
```

Install Confluent for Kubernetes by added the Confluent for Kubernetes Helm repository:

 ```phyton
c:\data_eng\házi\7\m12_kafkastreams_python_azure-master\terraform>helm repo add confluentinc https://packages.confluent.io/helm
"confluentinc" already exists with the same configuration, skipping

c:\data_eng\házi\7\m12_kafkastreams_python_azure-master\terraform>helm repo update
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "confluentinc" chart repository
Update Complete. ⎈Happy Helming!⎈

c:\data_eng\házi\7\m12_kafkastreams_python_azure-master\terraform>helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes
Release "confluent-operator" does not exist. Installing it now.
NAME: confluent-operator
LAST DEPLOYED: Tue Apr 29 10:54:14 2025
NAMESPACE: confluent
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
The Confluent Operator

The Confluent Operator brings the component (Confluent Services) specific controllers for kubernetes by providing components specific Custom Resource
Definition (CRD) as well as managing other Confluent Platform services
 ```

