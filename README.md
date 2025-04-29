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

Created resource list:

```phyton
c:\data_eng\házi\7\m12_kafkastreams_python_azure-master\terraform>kubectl get all -n confluent
NAME                                      READY   STATUS    RESTARTS   AGE
pod/confluent-operator-7bc56ff8bf-mlv6f   1/1     Running   0          8m42s

NAME                         TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
service/confluent-operator   ClusterIP   10.0.251.102   <none>        7778/TCP   8m42s

NAME                                 READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/confluent-operator   1/1     1            1           8m43s

NAME                                            DESIRED   CURRENT   READY   AGE
replicaset.apps/confluent-operator-7bc56ff8bf   1         1         1       8m43s
```
Then I authenticated with ACR:
```phyton
c:\data_eng\házi\7\m12_kafkastreams_python_azure-master\terraform>az acr login --name acr.azurecr.io
The login server endpoint suffix '.azurecr.io' is automatically omitted.
Login Succeeded

c:\data_eng\házi\7\m12_kafkastreams_python_azure-master\terraform>
```

### Build and push azure-connector into ACR

```phyton
Builded the Docker image:
c:\data_eng\házi\7\m12_kafkastreams_python_azure-master\connectors>docker build -t acr.azurecr.io/azure-connector:latest .
[+] Building 2.1s (7/7) FINISHED                                                                                                                                                            docker:desktop-linux
 => [internal] load build definition from Dockerfile                                                                                                                                                        0.0s
 => => transferring dockerfile: 306B                                                                                                                                                                        0.0s
 => [internal] load metadata for docker.io/confluentinc/cp-server-connect:7.6.0                                                                                                                             1.5s
 => [internal] load .dockerignore                                                                                                                                                                           0.0s
 => => transferring context: 2B                                                                                                                                                                             0.0s
 => [1/3] FROM docker.io/confluentinc/cp-server-connect:7.6.0@sha256:0ea4d                                                                       0.0s
 => => resolve docker.io/confluentinc/cp-server-connect:7.6.0@sha256:0bf9b70cc89a2dcdd9c57d2d1505c8c2ea4d                                                                       0.0s
 => CACHED [2/3] RUN confluent-hub install --no-prompt confluentinc/kafka-connect-azure-blob-storage:latest                                                                                                 0.0s
 => CACHED [3/3] RUN confluent-hub install --no-prompt confluentinc/kafka-connect-azure-blob-storage-source:latest                                                                                          0.0s
 => exporting to image                                                                                                                                                                                      0.3s
 => => exporting layers                                                                                                                                                                                     0.0s
 => => exporting manifest sha256:87ca0260cfdcd056f267803844e8749ad2ae16bb7d141870111626f432d97bfe                                                                                                           0.0s
 => => exporting config sha256:375d7db90c39b010366d8ee41dfd26469afd5e94c2672f4008568edf5e5ba1b5                                                                                                             0.0s
 => => exporting attestation manifest sha256:55e801d4d57fd000ae9bb0578282535cd14832c926f9383eb032d26a92491caa                                                                                               0.1s
 => => exporting manifest list sha256:7a2dfaed6988e53b5afeb9ddaa18a46af8539eea3b2d5dcc4460d6902a4dcb85                                                                                                      0.0s
 => => naming to accr.io/azure-connector:latest                                                                                                                                 0.0s
 => => unpacking to acr.io/azure-connector:latest                                                                                                                              0.0s
```

Then pushed it to the ACR:

```phyton
c:\data_eng\házi\7\m12_kafkastreams_python_azure-master\connectors>docker push a.azurecr.io/azure-connector
Using default tag: latest
The push refers to repository [acr.io/azure-connector]
f3e34be17d64: Pushed
0e55377ebe37: Pushed
4250354b4fb7: Pushed
d389b3791c2e: Pushed
5420596c14ab: Pushed
17fe3a92262f: Pushed
003d908e509f: Pushed
ddfc5620ff70: Pushed
c4c5f447179d: Pushed
974e7e336459: Pushed
fe36fc382320: Pushed
8fba90d6dcbd: Pushed
a266312a92ef: Pushed
186e9837369c: Pushed
da7039bb2113: Pushed
c24709eccb2a: Pushed
latest: digest: sha256:7a2d2d5dcc4460d6902a4dcb85 size: 856
```
After a few minutes I checked the the cluster initiated properly:

```phyton
c:\data_eng\házi\7\m12_kafkastreams_python_azure-master>kubectl get pods -o wide
NAME                                  READY   STATUS    RESTARTS        AGE     IP             NODE                              NOMINATED NODE   READINESS GATES
confluent-operator-7bc56ff8bf-mlv6f   1/1     Running   0               10h     10.244.0.166   aks-default-18464414-vmss000000   <none>           <none>
connect-0                             1/1     Running   0               5m42s   10.244.0.30    aks-default-18464414-vmss000000   <none>           <none>
controlcenter-0                       1/1     Running   0               3m10s   10.244.0.167   aks-default-18464414-vmss000000   <none>           <none>
elastic-0                             1/1     Running   4 (4m24s ago)   5m29s   10.244.0.141   aks-default-18464414-vmss000000   <none>           <none>
kafka-0                               1/1     Running   0               4m27s   10.244.0.101   aks-default-18464414-vmss000000   <none>           <none>
kafka-1                               1/1     Running   1 (3m44s ago)   4m27s   10.244.0.137   aks-default-18464414-vmss000000   <none>           <none>
kafka-2                               1/1     Running   0               4m27s   10.244.0.214   aks-default-18464414-vmss000000   <none>           <none>
ksqldb-0                              1/1     Running   0               3m11s   10.244.0.206   aks-default-18464414-vmss000000   <none>           <none>
schemaregistry-0                      1/1     Running   0               3m10s   10.244.0.78    aks-default-18464414-vmss000000   <none>           <none>
zookeeper-0                           1/1     Running   0               5m43s   10.244.0.20    aks-default-18464414-vmss000000   <none>           <none>
zookeeper-1                           1/1     Running   0               5m43s   10.244.0.35    aks-default-18464414-vmss000000   <none>           <none>
zookeeper-2                           1/1     Running   0               5m43s   10.244.0.229   aks-default-18464414-vmss000000   <none>           <none>
```

### Install Confluent Platform

Gone into root folder. Modified the file confluent-platform.yaml and replace the placeholder with actual value.
Then installed all Confluent Platform components:

```phyton
c:\data_eng\házi\7\m12_kafkastreams_python_azure-master>kubectl apply -f confluent-platform.yaml
zookeeper.platform.confluent.io/zookeeper created
kafka.platform.confluent.io/kafka created
connect.platform.confluent.io/connect created
ksqldb.platform.confluent.io/ksqldb created
controlcenter.platform.confluent.io/controlcenter created
schemaregistry.platform.confluent.io/schemaregistry created
```

Then installed a sample producer app and topic:

```phyton
c:\data_eng\házi\7\m12_kafkastreams_python_azure-master>kubectl apply -f producer-app-data.yaml
secret/kafka-client-config created
statefulset.apps/elastic created
service/elastic created
kafkatopic.platform.confluent.io/elastic-0 created
```

Then set up port-forwarding to COntrol Center web UI from local machine:

```phyton
PS C:\data_eng\házi\7\m12_kafkastreams_python_azure-master> Start-Process powershell -WindowStyle Hidden -ArgumentList 'kubectl port-forward controlcenter-0 9021:9021 *> $null'
```

![contcent](https://github.com/user-attachments/assets/1152df25-4e57-4ea6-a677-27854178d68c)

###  Create a kafka topic

The topic should have at least 3 partitions because the azure blob storage has 3 partitions. Name the new topic: expedia.

Created a connection for kafka:

```phyton
PS C:\data_eng\házi\7\m12_kafkastreams_python_azure-master> Start-Process powershell -WindowStyle Hidden -ArgumentList 'kubectl port-forward connect-0 8083:8083 *> $null'
```
Then created Kafka topic with a name 'expedia':

```phyton
c:\data_eng\házi\7\m12_kafkastreams_python_azure-master>kubectl exec kafka-0 -c kafka -- bash -c "/usr/bin/kafka-topics --create --topic expedia --replication-factor 3 --partitions 3 --bootstrap-server kafka:9092"
Created topic expedia.
```
Then uploaded the data files into Azure Conatainers:

![topics_uploaded](https://github.com/user-attachments/assets/e634b82f-2068-40b5-be6a-79289ad33c5d)

Then modified the file /terraform/azure-source-cc.json:

```phyton
{
"name": "expedia",
  "config": {
    "topics": "expedia",
    "bootstrap.servers": "kafka:9071",
    "connector.class": "io.confluent.connect.azure.blob.storage.AzureBlobStorageSourceConnector",
    "tasks.max": "2",
    "topics.dir": "root",
    "format.class": "io.confluent.connect.azure.blob.storage.format.avro.AvroFormat",
    "azblob.account.name": "",
    "azblob.account.key": "",
    "azblob.container.name": "data",
    "azblob.retry.retries": "3",
    "transforms": "mask_date",
    "transforms.mask_date.type": "org.apache.kafka.connect.transforms.MaskField$Value",
    "transforms.mask_date.fields": "date_time",
    "transforms.mask_date.replacement": "0000-00-00 00:00:00"
  }
}
```

Then uploaded the connector file through the API:

```phyton
PS C:\data_eng\házi\7\m12_kafkastreams_python_azure-master\terraform> curl -s -X POST -H "Content-Type:application/json" --data @azure-source-cc.json http://localhost:8083/connectors
{"name":"expedia","config":{"topics":"expedia","bootstrap.servers":"kafka:9071","connector.class":"io.confluent.connect.azure.blob.storage.AzureBlobStorageSourceConnector","tasks.max":"2","topics.dir":"root","format.class":"io.confluent.connect.azure.blob.storage.format.avro.AvroFormat","azblob.account.name":"dev","azblob.account.key":"","azblob.container.name":"data","azblob.retry.retries":"3","transforms":"mask_date","transforms.mask_date.type":"org.apache.kafka.connect.transforms.MaskField$Value","transforms.mask_date.fields":"date_time","transforms.mask_date.replacement":"0000-00-00 00:00:00","name":"expedia"},"tasks":[],"type":"source"}
PS C:\data_eng\házi\7\m12_kafkastreams_python_azure-master\terraform>
```
Then verified the messages in the Kafka in the Control Center:

![messages](https://github.com/user-attachments/assets/608e5bc9-8656-434a-98e3-60af9f677614)

Then created an output kafka topic:

```phyton
c:\data_eng\házi\7\m12_kafkastreams_python_azure-master>kubectl exec kafka-0 -c kafka -- bash -c "/usr/bin/kafka-topics --create --topic expedia_ext --replication-factor 3 --partitions 3 --bootstrap-server kafka:9092"
WARNING: Due to limitations in metric names, topics with a period ('.') or underscore ('_') could collide. To avoid issues it is best to use either, but not both.
Created topic expedia_ext.

c:\data_eng\házi\7\m12_kafkastreams_python_azure-master>
```

### Deploy Stream application

Verified the Kafka topic names in the /src/main.py:

```phyton
import datetime
from dateutil.parser import parse as parse_date
import faust
import logging


class ExpediaRecord(faust.Record):
    id: float
    date_time: str
    site_name: int
    posa_container: int
    user_location_country: int
    user_location_region: int
    user_location_city: int
    orig_destination_distance: float
    user_id: int
    is_mobile: int
    is_package: int
    channel: int
    srch_ci: str
    srch_co: str
    srch_adults_cnt: int
    srch_children_cnt: int
    srch_rm_cnt: int
    srch_destination_id: int
    srch_destination_type_id: int
    hotel_id: int


class ExpediaExtRecord(ExpediaRecord):
    stay_category: str


logger = logging.getLogger(__name__)
app = faust.App('kafkastreams', broker='kafka://kafka:9092')
source_topic = app.topic('expedia', value_type=ExpediaRecord)
destination_topic = app.topic('expedia_ext', value_type=ExpediaExtRecord)


@app.agent(source_topic, sink=[destination_topic])
async def handle(messages):
    async for message in messages:
        if message is None:
            logger.info('No messages')
            continue

        data = {
            'id': message.id,
            'date_time': message.date_time,
            'site_name': message.site_name,
            'posa_container': message.posa_container,
            'user_location_country': message.user_location_country,
            'user_location_region': message.user_location_region,
            'user_location_city': message.user_location_city,
            'orig_destination_distance': message.orig_destination_distance,
            'user_id': message.user_id,
            'is_mobile': message.is_mobile,
            'is_package': message.is_package,
            'channel': message.channel,
            'srch_ci': message.srch_ci,
            'srch_co': message.srch_co,
            'srch_adults_cnt': message.srch_adults_cnt,
            'srch_children_cnt': message.srch_children_cnt,
            'srch_rm_cnt': message.srch_rm_cnt,
            'srch_destination_id': message.srch_destination_id,
            'srch_destination_type_id': message.srch_destination_type_id,
            'hotel_id': message.hotel_id
        }

        # Set default value for stay category
        stay_category = 'Erroneous data'

        try:
            # Parse check-in and check-out dates. All incorrect values is filtering
            # on this stage
            check_in = parse_date(message.srch_ci)
            check_out = parse_date(message.srch_co)

        except:
            yield ExpediaExtRecord(**data, stay_category=stay_category)

        # Calculate the duration in days
        duration = (check_out - check_in).days

        # Determine stay category for correct dates
        if 1 <= duration <=4:
            stay_category = 'Short stay'
        elif 5 <= duration <= 10:
            stay_category = 'Standard stay'
        elif 11 <= duration <= 14:
            stay_category = 'Standard extended stay'
        elif duration > 14:
            stay_category = 'Long stay'

        yield ExpediaExtRecord(**data, stay_category=stay_category)


if __name__ == '__main__':
    app.main()
```

Then built the stram-app docker image:

```python
c:\data_eng\házi\7\m12_kafkastreams_python_azure-master>docker build -t ac.azurecr.io/stream-app:latest .
[+] Building 106.4s (11/11) FINISHED                                                                                                                                                        docker:desktop-linux
 => [internal] load build definition from Dockerfile                                                                                                                                                        0.1s
 => => transferring dockerfile: 286B                                                                                                                                                                        0.0s
 => [internal] load metadata for docker.io/library/python:3.9                                                                                                                                               2.3s
 => [internal] load .dockerignore                                                                                                                                                                           0.1s
 => => transferring context: 2B                                                                                                                                                                             0.0s
 => [1/6] FROM docker.io/library/python:3.9@sha256:5e936c602d41bc50a5de796d8f6ce6a223faffffe36445838ead2255b1c0699b                                                                                        65.9s
 => => resolve docker.io/library/python:3.9@sha256:5e936c602d41bc50a5de796d8f6ce6a223faffffe36445838ead2255b1c0699b                                                                                         0.1s
 => => sha256:c11e4fe34802ddc4646a0639eb778393c0823872b9dd0df5fd00e0618a47b28b 250B / 250B                                                                                                                  0.2s
 => => sha256:80b896d41308c2d1ff108791b7714ed106ae72c1f9a8a9afe4e8e3041a9468c2 19.85MB / 19.85MB                                                                                                            6.0s
 => => sha256:992bfc873aeeccec61984e5cf95389f133ec6a19e3513c799c1d47dee4fbe62e 6.16MB / 6.16MB                                                                                                              3.8s
 => => sha256:c187b51b626e1d60ab369727b81f440adea9d45e97a45e137fc318be0bb7f09f 211.36MB / 211.36MB                                                                                                         46.2s
 => => sha256:ca513cad200b13ead2c745498459eed58a6db3480e3ba6117f854da097262526 64.39MB / 64.39MB                                                                                                           31.7s
 => => sha256:63964a8518f54dc31f8df89d7f06714c7a793aa1aa08a64ae3d7f4f4f30b4ac8 24.01MB / 24.01MB                                                                                                           15.9s
 => => sha256:cf05a52c02353f0b2b6f9be0549ac916c3fb1dc8d4bacd405eac7f28562ec9f2 48.49MB / 48.49MB                                                                                                           21.3s
 => => extracting sha256:cf05a52c02353f0b2b6f9be0549ac916c3fb1dc8d4bacd405eac7f28562ec9f2                                                                                                                  18.9s
 => => extracting sha256:63964a8518f54dc31f8df89d7f06714c7a793aa1aa08a64ae3d7f4f4f30b4ac8                                                                                                                   2.1s
 => => extracting sha256:ca513cad200b13ead2c745498459eed58a6db3480e3ba6117f854da097262526                                                                                                                   4.3s
 => => extracting sha256:c187b51b626e1d60ab369727b81f440adea9d45e97a45e137fc318be0bb7f09f                                                                                                                  11.1s
 => => extracting sha256:992bfc873aeeccec61984e5cf95389f133ec6a19e3513c799c1d47dee4fbe62e                                                                                                                   0.4s
 => => extracting sha256:80b896d41308c2d1ff108791b7714ed106ae72c1f9a8a9afe4e8e3041a9468c2                                                                                                                   1.1s
 => => extracting sha256:c11e4fe34802ddc4646a0639eb778393c0823872b9dd0df5fd00e0618a47b28b                                                                                                                   0.1s
 => [internal] load build context                                                                                                                                                                           0.2s
 => => transferring context: 3.72kB                                                                                                                                                                         0.0s
 => [2/6] ADD src/main.py /app/main.py                                                                                                                                                                      1.3s
 => [3/6] ADD requirements.txt /app/requirements.txt                                                                                                                                                        0.1s
 => [4/6] WORKDIR /app                                                                                                                                                                                      0.1s
 => [5/6] RUN apt-get update && apt-get install -y     gcc                                                                                                                                                  8.3s
 => [6/6] RUN pip3 install -r requirements.txt                                                                                                                                                             20.7s
 => exporting to image                                                                                                                                                                                      7.0s
 => => exporting layers                                                                                                                                                                                     5.0s
 => => exporting manifest sha256:d1647a6a2ac80cb32fe7095ccf6760a077cad57070b84506d62bf2157c930443                                                                                                           0.0s
 => => exporting config sha256:90927672a3cec7d7ab5fdcb08b61a430f2ebf381b91aefd3c6119b047adc772d                                                                                                             0.1s
 => => exporting attestation manifest sha256:a8129240dc44a6c926be03af27376e20e410cc7dba267f9f78864493ac924916                                                                                               0.1s
 => => exporting manifest list sha256:40b04f8080746fc0fdc0ead90c1dca3c7a00cd0a57b5dc8055dc87c65d124bc7                                                                                                      0.0s
 => => naming to acr.azurecr.io/stream-app:latest                                                                                                                                      0.0s
 => => unpacking to acr.azurecr.io/stream-app:latest  
```

And pushed it to the ACR:

```python
c:\data_eng\házi\7\m12_kafkastreams_python_azure-master>docker push ac.azurecr.io/stream-app:latest
The push refers to repository [acr.azurecr.io/stream-app]
47e60730f87f: Pushed
80b896d41308: Pushed
c11e4fe34802: Pushed
ca513cad200b: Pushed
e160e3bbfa68: Pushed
4f4fb700ef54: Pushed
3b4c279150f1: Pushed
53ac2a08907c: Pushed
cf05a52c0235: Pushed
63964a8518f5: Pushed
c187b51b626e: Pushed
c7ee4621ffc6: Pushed
992bfc873aee: Pushed
latest: digest: sha256:40b04f8080746fc0fdc0ead90c1dca3c7a00cd0a57b5dc8055dc87c65d124bc7 size: 856
```

Part of the deploying Stream Application into AKS, I modified the stram-app.yaml's image related row, then deployed it:

```python
c:\data_eng\házi\7\m12_kafkastreams_python_azure-master>kubectl apply -f stream-app.yaml
deployment.apps/kstream-app created
```

As you can see it was deployed properly into the cluster:

```python
c:\data_eng\házi\7\m12_kafkastreams_python_azure-master>kubectl get pods -o wide
NAME                                  READY   STATUS    RESTARTS      AGE   IP             NODE                              NOMINATED NODE   READINESS GATES
confluent-operator-7bc56ff8bf-mlv6f   1/1     Running   0             11h   10.244.0.166   aks-default-18464414-vmss000000   <none>           <none>
connect-0                             1/1     Running   0             68m   10.244.0.30    aks-default-18464414-vmss000000   <none>           <none>
controlcenter-0                       1/1     Running   0             23m   10.244.0.219   aks-default-18464414-vmss000000   <none>           <none>
elastic-0                             1/1     Running   4 (66m ago)   68m   10.244.0.141   aks-default-18464414-vmss000000   <none>           <none>
kafka-0                               1/1     Running   0             67m   10.244.0.101   aks-default-18464414-vmss000000   <none>           <none>
kafka-1                               1/1     Running   1 (66m ago)   67m   10.244.0.137   aks-default-18464414-vmss000000   <none>           <none>
kafka-2                               1/1     Running   0             67m   10.244.0.214   aks-default-18464414-vmss000000   <none>           <none>
ksqldb-0                              1/1     Running   0             65m   10.244.0.206   aks-default-18464414-vmss000000   <none>           <none>
kstream-app-7b74bf575d-sx62n          1/1     Running   0             23s   10.244.0.143   aks-default-18464414-vmss000000   <none>           <none>
schemaregistry-0                      1/1     Running   0             65m   10.244.0.78    aks-default-18464414-vmss000000   <none>           <none>
zookeeper-0                           1/1     Running   0             68m   10.244.0.20    aks-default-18464414-vmss000000   <none>           <none>
zookeeper-1                           1/1     Running   0             68m   10.244.0.35    aks-default-18464414-vmss000000   <none>           <none>
zookeeper-2                           1/1     Running   0             68m   10.244.0.229   aks-default-18464414-vmss000000   <none>           <none>
```



