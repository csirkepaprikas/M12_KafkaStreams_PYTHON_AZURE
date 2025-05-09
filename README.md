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

Then I verified the messages in the Control Center's Topic menu, by the expedia_ext topic:

![exp_ext_messa](https://github.com/user-attachments/assets/9a6036af-9755-4144-a268-7c36d9d3e6c2)

### Visualize Data from Kafka Topic expedia_ext with KSQL

Then started by running the following command to access the KSQL command prompt:

```python
c:\data_eng\házi\7\m12_kafkastreams_python_azure-master>kubectl exec -it ksqldb-0 -- ksql
Defaulted container "ksqldb" out of: ksqldb, config-init-container (init)
WARNING: Unable to create command history file '/home/appuser/?/.ksql-history', command history will not be saved.

                  ===========================================
                  =       _              _ ____  ____       =
                  =      | | _____  __ _| |  _ \| __ )      =
                  =      | |/ / __|/ _` | | | | |  _ \      =
                  =      |   <\__ \ (_| | | |_| | |_) |     =
                  =      |_|\_\___/\__, |_|____/|____/      =
                  =                   |_|                   =
                  =        The Database purpose-built       =
                  =        for stream processing apps       =
                  ===========================================

Copyright 2017-2022 Confluent Inc.

CLI v7.8.0, Server v7.8.0 located at http://localhost:8088
Server Status: RUNNING

Having trouble? Type 'help' (case-insensitive) for a rundown of how things work!
```

I was redirected in KSQL command promt, where I created a stream from expedia_ext topic:

```python
ksql>     CREATE STREAM expedia_stream (
>        id BIGINT,
>        hotel_id BIGINT,
>        stay_category VARCHAR
>    ) WITH (
>        KAFKA_TOPIC='expedia_ext',
>        VALUE_FORMAT='JSON'
>    );
>

 Message
----------------
 Stream created
----------------
```

Then I created a table from stream as select query:

```python
ksql>    CREATE TABLE hotels_count AS
>    SELECT
>        stay_category,
>        COUNT(hotel_id) AS hotels_amount,
>        COUNT_DISTINCT(hotel_id) AS distinct_hotels
>    FROM expedia_stream
>    GROUP BY stay_category;
>

 Message
-------------------------------------------
 Created query with ID CTAS_HOTELS_COUNT_1
```

Then I retrieved the total number of hotels (hotel_id) and the number of distinct hotels per category:

```python
ksql> SELECT * FROM hotels_count EMIT CHANGES;
+-------------------------------------------------------------------+-------------------------------------------------------------------+-------------------------------------------------------------------+
|STAY_CATEGORY                                                      |HOTELS_AMOUNT                                                      |DISTINCT_HOTELS                                                    |
+-------------------------------------------------------------------+-------------------------------------------------------------------+-------------------------------------------------------------------+
|Erroneous data                                                     |61                                                                 |61                                                                 |
|Standard extended stay                                             |267                                                                |246                                                                |
|Short stay                                                         |40552                                                              |2486                                                               |
|Long stay                                                          |117                                                                |115                                                                |
|Standard stay                                                      |4528                                                               |2051                                                               |
|Long stay                                                          |118                                                                |116                                                                |
|Standard stay                                                      |4536                                                               |2052                                                               |
|Standard stay                                                      |4547                                                               |2052                                                               |
|Standard stay                                                      |4572                                                               |2055                                                               |
|Standard extended stay                                             |269                                                                |248                                                                |
|Standard stay                                                      |4575                                                               |2055                                                               |
|Short stay                                                         |41185                                                              |2486                                                               |
|Standard stay                                                      |4583                                                               |2056                                                               |
|Short stay                                                         |41511                                                              |2486                                                               |
|Standard extended stay                                             |273                                                                |252                                                                |
|Long stay                                                          |119                                                                |117                                                                |
|Standard stay                                                      |4636                                                               |2065                                                               |
|Short stay                                                         |41734                                                              |2486                                                               |
|Standard extended stay                                             |276                                                                |255                                                                |
|Long stay                                                          |120                                                                |118                                                                |
|Standard stay                                                      |4667                                                               |2068                                                               |
|Short stay                                                         |42012                                                              |2486                                                               |
|Standard extended stay                                             |278                                                                |257                                                                |
|Long stay                                                          |122                                                                |120                                                                |
|Standard stay                                                      |4698                                                               |2076                                                               |
|Short stay                                                         |42324                                                              |2486                                                               |
|Long stay                                                          |123                                                                |121                                                                |
|Standard stay                                                      |4739                                                               |2085                                                               |
|Short stay                                                         |42512                                                              |2486                                                               |
|Standard extended stay                                             |280                                                                |259                                                                |
|Long stay                                                          |124                                                                |122                                                                |
|Standard stay                                                      |4756                                                               |2088                                                               |
|Short stay                                                         |42589                                                              |2486                                                               |
|Standard extended stay                                             |281                                                                |260                                                                |
|Long stay                                                          |128                                                                |126                                                                |
|Standard stay                                                      |4813                                                               |2099                                                               |
|Short stay                                                         |42885                                                              |2486                                                               |
|Standard extended stay                                             |283                                                                |262                                                                |
|Erroneous data                                                     |62                                                                 |62                                                                 |
|Long stay                                                          |133                                                                |132                                                                |
|Standard stay                                                      |4856                                                               |2107                                                               |
|Short stay                                                         |43256                                                              |2486                                                               |
|Erroneous data                                                     |64                                                                 |64                                                                 |
|Standard extended stay                                             |285                                                                |264                                                                |
|Short stay                                                         |43773                                                              |2486                                                               |
|Standard extended stay                                             |289                                                                |268                                                                |
|Long stay                                                          |135                                                                |133                                                                |
|Standard stay                                                      |4925                                                               |2123                                                               |
|Short stay                                                         |44175                                                              |2486                                                               |
|Erroneous data                                                     |65                                                                 |64                                                                 |
|Standard extended stay                                             |292                                                                |271                                                                |
|Long stay                                                          |136                                                                |134                                                                |
|Standard stay                                                      |4975                                                               |2126                                                               |
|Short stay                                                         |44811                                                              |2486                                                               |
|Erroneous data                                                     |66                                                                 |65                                                                 |
|Standard extended stay                                             |297                                                                |276                                                                |
|Long stay                                                          |143                                                                |141                                                                |
```

Then I checked the stream topology in the Flow vizualization:

![flow](https://github.com/user-attachments/assets/b5044d69-91e5-4dd8-9a8d-838bec77e8f2)

### CI/CD

For CI/CD tasks were written in a Makefile - and the realted secrets in the secrets.env file - and the execution was carried out in PowerShell. I made some modifications by the visulazation part, for the external stream topic, table creation and the task query I applied API calls and for the easier access of the ksqldb I used port-forwarding.

The actual Makefile:

```python
# Makefile
include secrets.env
export


IMAGE_NAME_CON = azure-connector
IMAGE_NAME_KSTR = stream-app
TAG = latest
FULL_IMAGE_CON = $(ACR_NAME).azurecr.io/$(IMAGE_NAME_CON):$(TAG)
FULL_IMAGE_KSTR = $(ACR_NAME).azurecr.io/$(IMAGE_NAME_KSTR):$(TAG)
CONTAINER = data

# YAML files' path
CONFLUENT_YAML = k8s/confluent-platform.yaml
PRODUCER_YAML = k8s/producer-app-data.yaml
STREAM_APP_YAML = k8s/stream-app.yaml

upload-dir:
	az storage blob upload-batch \
		--account-name $(STORAGE_ACCOUNT) \
		--destination $(CONTAINER) \
		--source . \
		--pattern "root_cicd/*"


# Login to Azure and ACR
login:
	az acr login --name $(ACR_NAME)


# Build image_con
build_con:
	docker build -t $(FULL_IMAGE_CON) -f connectors/Dockerfile .

# Push con_image to ACR
push_con:
	docker push $(FULL_IMAGE_CON)
	
# Build image_kstr
build_kstr:
	docker build -t $(FULL_IMAGE_KSTR) .

# Push kstr_image to ACR
push_kstr: 
	docker push $(FULL_IMAGE_KSTR)


# Confluent deployment
deploy-confluent:
	kubectl apply -f $(CONFLUENT_YAML)

# Producer-app deployment
deploy-producer:
	kubectl apply -f $(PRODUCER_YAML)	

# Confluent deletion
delete-confluent:
	kubectl delete -f $(CONFLUENT_YAML) 

# Producer-app deletion
delete-producer:
	kubectl delete -f $(PRODUCER_YAML)	
	
# Status verification
status:
	kubectl get pods -o wide  
	
	
# Port forward Control Center
port-forward-controlcenter:
	kubectl port-forward controlcenter-0 9021:9021 &


# Port forward Kafka Connect
port-forward-connect:
	kubectl port-forward connect-0 8083:8083 &

# Kafka topic creation (expedia)
create-topic:
	kubectl exec kafka-0 -c kafka -- bash -c "/usr/bin/kafka-topics --create --topic expedia --replication-factor 3 --partitions 3 --bootstrap-server kafka:9092"

# Delete alias
fix-curl:
	powershell -Command "Remove-Item alias:curl"


# Kafka Connect connector upload from JSON file
upload-connector:
	powershell -Command "Invoke-RestMethod -Method Post -Uri http://localhost:8083/connectors -ContentType 'application/json' -Body (Get-Content -Raw -Path azure-source-cc.json)"
	
# Create an output kafka topic
output-topic:
	kubectl exec kafka-0 -c kafka -- bash -c '/usr/bin/kafka-topics --create --topic expedia_ext --replication-factor 3 --partitions 3 --bootstrap-server kafka:9092'

# Stream application deployment
deploy-stream-app:
	kubectl apply -f $(STREAM_APP_YAML)

# Stream application deletion
delete-stream-app:
	kubectl delete -f $(STREAM_APP_YAML)
	
# Command to access the KSQL command prompt
ksql-access:
	kubectl exec -it ksqldb-0 -- ksql
	
# Port forward for ksqldb:
port-forward-ksqldb:
	kubectl port-forward connect-0 8088:8088 &

# Create a stream from expedia_ext topic0
create_stream:
	curl -X POST http://localhost:8088/ksql \
	-H "Content-Type: application/vnd.ksql.v1+json; charset=utf-8" \
	-d @ksql/create_stream.json

# Create table from stream as select query
create_table:
	curl -X POST http://localhost:8088/ksql \
	-H "Content-Type: application/vnd.ksql.v1+json; charset=utf-8" \
	-d @ksql/create_table.json

# Retrieve the total number of hotels (hotel_id) and the number of distinct hotels per category
select_hotels:
	curl -X POST http://localhost:8088/query \
	-H "Content-Type: application/vnd.ksql.v1+json; charset=utf-8" \
	-d @ksql/select_hotels.json
```

First I uploaded the data's to the container:

```python
PS C:\data_eng\házi\7\ci_cd> make upload-dir
Makefile:41: warning: overriding recipe for target 'build_con'
Makefile:33: warning: ignoring old recipe for target 'build_con'
Makefile:45: warning: overriding recipe for target 'push_con'
Makefile:37: warning: ignoring old recipe for target 'push_con'
az storage blob upload-batch \
        --account-name dev \
        --destination d \
        --source . \
        --pattern "root_cicd/*"

There are no credentials provided in your command and environment, we will query for account key for your storage account.
It is recommended to provide --connection-string, --account-key or --sas-token in your command as credentials.

You also can add `--auth-mode login` in your command to use Azure Active Directory (Azure AD) for authorization if your login account is assigned required RBAC roles.
For more information about RBAC roles in storage, visit https://learn.microsoft.com/azure/storage/common/storage-auth-aad-rbac-cli.

In addition, setting the corresponding environment variables can avoid inputting credentials in your command. Please use --help to get more information about environment variable usage.
Finished[#############################################################]  100.0000%
[
  {
    "Blob": "https://dev.blob.core.windows.net/data/root_cicd/topics/expedia/partition%3D0/expedia%2B0%2B0000000000.avro",
    "Last Modified": "2025-05-02T17:15:01+00:00",
    "Type": null,
    "eTag": "\"0x8DD899CDF4486EC\""
  },
  {
    "Blob": "https://dev.blob.core.windows.net/data/root_cicd/topics/expedia/partition%3D1/expedia%2B1%2B0000000000.avro",
    "Last Modified": "2025-05-02T17:15:24+00:00",
    "Type": null,
    "eTag": "\"0x8DD899CED626A50\""
  },
  {
    "Blob": "https://de.blob.core.windows.net/data/root_cicd/topics/expedia/partition%3D2/expedia%2B2%2B0000000000.avro",
    "Last Modified": "2025-05-02T17:15:50+00:00",
    "Type": null,
    "eTag": "\"0x8DD899CFC9BB4E8\""
  }
]
PS C:\data_eng\házi\7\ci_cd>

```

![cicd_data](https://github.com/user-attachments/assets/6e1f4fa0-4d59-44d1-aad7-c2e0c6bfa068)


Then I loddeg in to the ACR:
```python
PS C:\data_eng\házi\7\ci_cd> make login
az acr login --name acr
Login Succeeded
PS C:\data_eng\házi\7\ci_cd
```

And builded the Connector's image:
```python
PS C:\data_eng\házi\7\ci_cd> make build_con
docker build -t acr.azurecr.io/azure-connector:latest -f connectors/Dockerfile .
[+] Building 2.0s (7/7) FINISHED                                                                                                       docker:desktop-linux
 => [internal] load build definition from Dockerfile                                                                                                   0.0s
 => => transferring dockerfile: 306B                                                                                                                   0.0s
 => [internal] load metadata for docker.io/confluentinc/cp-server-connect:7.6.0                                                                        1.3s
 => [internal] load .dockerignore                                                                                                                      0.0s
 => => transferring context: 2B                                                                                                                        0.0s
 => [1/3] FROM docker.io/confluentinc/cp-server-connect:7.6.0@sha256:0bf9b70cc89a2dcdd9c57d2d92129dfbb012690a3323f4c4e92d1505c8c2ea4d                  0.1s
 => => resolve docker.io/confluentinc/cp-server-connect:7.6.0@sha256:0bf9b70cc89a2dcdd9c57d2d92129dfbb012690a3323f4c4e92d1505c8c2ea4d                  0.0s
 => CACHED [2/3] RUN confluent-hub install --no-prompt confluentinc/kafka-connect-azure-blob-storage:latest                                            0.0s
 => CACHED [3/3] RUN confluent-hub install --no-prompt confluentinc/kafka-connect-azure-blob-storage-source:latest                                     0.0s
 => exporting to image                                                                                                                                 0.3s
 => => exporting layers                                                                                                                                0.0s
 => => exporting manifest sha256:87ca0260cfdcd056f267803844e8749ad2ae16bb7d141870111626f432d97bfe                                                      0.0s
 => => exporting config sha256:375d7db90c39b010366d8ee41dfd26469afd5e94c2672f4008568edf5e5ba1b5                                                        0.0s
 => => exporting attestation manifest sha256:661fe0cb96daffeb6da663b8cbd44526cb930bd2fac7b3d20c8ac3e8c6a40ed5                                          0.1s
 => => exporting manifest list sha256:029bea512876172a6df04c1f37a8be6af1e9acbeafdf35a5429e8a16b9205ede                                                 0.0s
 => => naming to acr.azurecr.io/azure-connector:latest                                                                            0.0s
 => => unpacking to acrazurecr.io/azure-connector:latest                                                                         0.0s
PS C:\data_eng\házi\7\ci_cd>
```

Then I pushed the Connector image to the ACR:
```python
PS C:\data_eng\házi\7\ci_cd> make push_con
docker push acr.azurecr.io/azure-connector:latest
The push refers to repository [acr.azurecr.io/azure-connector]
186e9837369c: Layer already exists
da7039bb2113: Layer already exists
fe36fc382320: Layer already exists
17fe3a92262f: Layer already exists
5420596c14ab: Layer already exists
d00353b5eb83: Pushed
0e55377ebe37: Layer already exists
8fba90d6dcbd: Layer already exists
a266312a92ef: Layer already exists
c24709eccb2a: Layer already exists
003d908e509f: Layer already exists
d389b3791c2e: Layer already exists
ddfc5620ff70: Layer already exists
4250354b4fb7: Layer already exists
c4c5f447179d: Layer already exists
974e7e336459: Layer already exists
latest: digest: sha256:029bea512876172a6df04c1f37a8be6af1e9acbeafdf35a5429e8a16b9205ede size: 856
```

Then builded the Stream Application's image:

```python
PS C:\data_eng\házi\7\ci_cd> make build_kstr
docker build -t ac.azurecr.io/stream-app:latest .
[+] Building 3.2s (11/11) FINISHED                                                                                                                                                          docker:desktop-linux
 => [internal] load build definition from Dockerfile                                                                                                                                                        0.1s
 => => transferring dockerfile: 286B                                                                                                                                                                        0.0s
 => [internal] load metadata for docker.io/library/python:3.9                                                                                                                                               2.7s
 => [internal] load .dockerignore                                                                                                                                                                           0.0s
 => => transferring context: 2B                                                                                                                                                                             0.0s
 => [1/6] FROM docker.io/library/python:3.9@sha256:2b5aeaeccd9b6d8a54541c5f8406cb1d68a09ff9cd7ee7034f2d7d589a40e16c                                                                                         0.0s
 => => resolve docker.io/library/python:3.9@sha256:2b5aeaeccd9b6d8a54541c5f8406cb1d68a09ff9cd7ee7034f2d7d589a40e16c                                                                                         0.0s
 => [internal] load build context                                                                                                                                                                           0.0s
 => => transferring context: 92B                                                                                                                                                                            0.0s
 => CACHED [2/6] ADD src/main.py /app/main.py                                                                                                                                                               0.0s
 => CACHED [3/6] ADD requirements.txt /app/requirements.txt                                                                                                                                                 0.0s
 => CACHED [4/6] WORKDIR /app                                                                                                                                                                               0.0s
 => CACHED [5/6] RUN apt-get update && apt-get install -y     gcc                                                                                                                                           0.0s
 => CACHED [6/6] RUN pip3 install -r requirements.txt                                                                                                                                                       0.0s
 => exporting to image                                                                                                                                                                                      0.2s
 => => exporting layers                                                                                                                                                                                     0.0s
 => => exporting manifest sha256:d1647a6a2ac80cb32fe7095ccf6760a077cad57070b84506d62bf2157c930443                                                                                                           0.0s
 => => exporting config sha256:90927672a3cec7d7ab5fdcb08b61a430f2ebf381b91aefd3c6119b047adc772d                                                                                                             0.0s
 => => exporting attestation manifest sha256:d00e478b016702d98f91a0c25d37b53dfebf84a7eb8fe3d52ef62ae4448a12e9                                                                                               0.1s
 => => exporting manifest list sha256:7cbc3c2e39628a7011af1ba91c59ee92f098dbebda0946e3c050a5fb111f779a                                                                                                      0.0s
 => => naming to ac.azurecr.io/stream-app:latest                                                                                                                                      0.0s
 => => unpacking to acr.azurecr.io/stream-app:latest    
```

And I pushed the Stream Application's image to the ACR:

```python
PS C:\data_eng\házi\7\ci_cd> make push_kstr
docker push acr.azurecr.io/stream-app:latest
The push refers to repository [ac.azurecr.io/stream-app]
cf05a52c0235: Layer already exists
ca513cad200b: Layer already exists
992bfc873aee: Layer already exists
27c5ec60c1bf: Pushed
3b4c279150f1: Layer already exists
53ac2a08907c: Layer already exists
c7ee4621ffc6: Layer already exists
4f4fb700ef54: Layer already exists
e160e3bbfa68: Layer already exists
63964a8518f5: Layer already exists
80b896d41308: Layer already exists
c187b51b626e: Layer already exists
c11e4fe34802: Layer already exists
latest: digest: sha256:7cbc3c2e39628a7011af1ba91c59ee92f098dbebda0946e3c050a5fb111f779a size: 856
```

Then I created the Confluent Platform components, producer and topic:

```python
PS C:\data_eng\házi\7\ci_cd> make deploy-confluent
kubectl apply -f k8s/confluent-platform.yaml
zookeeper.platform.confluent.io/zookeeper created
kafka.platform.confluent.io/kafka created
connect.platform.confluent.io/connect created
ksqldb.platform.confluent.io/ksqldb created
controlcenter.platform.confluent.io/controlcenter created
schemaregistry.platform.confluent.io/schemaregistry created
PS C:\data_eng\házi\7\ci_cd> make deploy-producer
kubectl apply -f k8s/producer-app-data.yaml
secret/kafka-client-config created
statefulset.apps/elastic created
service/elastic created
kafkatopic.platform.confluent.io/elastic-0 created
```

Then I checked the cluster after 10 minutes:

```python
NAME                                  READY   STATUS    RESTARTS   AGE     IP             NODE                              NOMINATED NODE   READINESS GATES
confluent-operator-7bc56ff8bf-m874s   1/1     Running   0          2d20h   10.244.0.4     aks-default-18464414-vmss000000   <none>           <none>
connect-0                             1/1     Running   0          5m6s    10.244.0.31    aks-default-18464414-vmss000000   <none>           <none>
controlcenter-0                       1/1     Running   0          2m50s   10.244.0.162   aks-default-18464414-vmss000000   <none>           <none>
elastic-0                             1/1     Running   0          3m21s   10.244.0.56    aks-default-18464414-vmss000000   <none>           <none>
kafka-0                               1/1     Running   0          3m51s   10.244.0.47    aks-default-18464414-vmss000000   <none>           <none>
kafka-1                               1/1     Running   0          3m51s   10.244.0.171   aks-default-18464414-vmss000000   <none>           <none>
kafka-2                               1/1     Running   0          3m51s   10.244.0.11    aks-default-18464414-vmss000000   <none>           <none>
ksqldb-0                              1/1     Running   0          2m50s   10.244.0.15    aks-default-18464414-vmss000000   <none>           <none>
schemaregistry-0                      1/1     Running   0          2m49s   10.244.0.203   aks-default-18464414-vmss000000   <none>           <none>
zookeeper-0                           1/1     Running   0          5m7s    10.244.0.123   aks-default-18464414-vmss000000   <none>           <none>
zookeeper-1                           1/1     Running   0          5m7s    10.244.0.241   aks-default-18464414-vmss000000   <none>           <none>
zookeeper-2                           1/1     Running   0          5m7s    10.244.0.3     aks-default-18464414-vmss000000   <none>           <none>
```

Then I set up port forwarding to Control Center web UI from local machine:

```python
PS C:\data_eng\házi\7\ci_cd> make port-forward-controlcenter
kubectl port-forward controlcenter-0 9021:9021 &
Forwarding from 127.0.0.1:9021 -> 9021
Forwarding from [::1]:9021 -> 9021
Handling connection for 9021
Handling connection for 9021
Handling connection for 9021
Handling connection for 9021
Handling connection for 9021
Handling connection for 9021
Handling connection for 9021
Handling connection for 9021
Handling connection for 9021
Handling connection for 9021
```

And then I checked the GUI:

![ciccd_contcent](https://github.com/user-attachments/assets/de5e26d3-dc5c-409f-9c05-56399298eeda)

Then created a connection for kafka:

```python
PS C:\data_eng\házi\7\ci_cd> make port-forward-connect
kubectl port-forward connect-0 8083:8083 &
Forwarding from 127.0.0.1:8083 -> 8083
Forwarding from [::1]:8083 -> 8083
```

Then executed below command to create Kafka topic with a name 'expedia':

```python
PS C:\data_eng\házi\7\ci_cd> make create-topic
kubectl exec kafka-0 -c kafka -- bash -c "/usr/bin/kafka-topics --create --topic expedia --replication-factor 3 --partitions 3 --bootstrap-server kafka:9092"
Created topic expedia.
```

Then I deleted the alias:

```python
PS C:\data_eng\házi\7\ci_cd> make fix-curl
powershell -Command "Remove-Item alias:curl"
PS C:\data_eng\házi\7\ci_cd>
```

I uploaded the connector file through the API:

PS C:\data_eng\házi\7\ci_cd> make upload-connector
powershell -Command "Invoke-RestMethod -Method Post -Uri http://localhost:8083/connectors -ContentType 'application/json' -Body (Get-Content -Raw -Path azure-source-cc.json)"

```python
name    config
----    ------
expedia @{topics=expedia; bootstrap.servers=kafka:9071; connector.class=io.confluent.connect.azure.blob.storage.Azur...
```

Then I verified the messages in Kafka GUI, in the Topics/Expedia:

![cicd_messa](https://github.com/user-attachments/assets/ac2de0e5-a33a-4d28-baf9-a5889af4afe2)

I created an output kafka topic:

```python
PS C:\data_eng\házi\7\ci_cd> make output-topic
kubectl exec kafka-0 -c kafka -- bash -c '/usr/bin/kafka-topics --create --topic expedia_ext --replication-factor 3 --partitions 3 --bootstrap-server kafka:9092'
WARNING: Due to limitations in metric names, topics with a period ('.') or underscore ('_') could collide. To avoid issues it is best to use either, but not both.
Created topic expedia_ext.
```

Then I deployed Stream application from the image I builded and pushed to the ACR earlier:

```python
c:\data_eng\házi\7\ci_cd>make deploy-stream-app
kubectl apply -f k8s/stream-app.yaml
deployment.apps/kstream-app created
```

The pod was created successfully:

```python
c:\data_eng\házi\7\ci_cd>kubectl get pods
NAME                                  READY   STATUS    RESTARTS   AGE
confluent-operator-7bc56ff8bf-m874s   1/1     Running   0          2d22h
connect-0                             1/1     Running   0          73m
controlcenter-0                       1/1     Running   0          13m
elastic-0                             1/1     Running   0          71m
kafka-0                               1/1     Running   0          72m
kafka-1                               1/1     Running   0          72m
kafka-2                               1/1     Running   0          6m8s
ksqldb-0                              1/1     Running   0          71m
kstream-app-7b74bf575d-xfwvf          1/1     Running   0          43s
schemaregistry-0                      1/1     Running   0          71m
zookeeper-0                           1/1     Running   0          73m
zookeeper-1                           1/1     Running   0          73m
zookeeper-2                           1/1     Running   0          73m
```

Then I checked the message in the expedia_ext topic:

![cicd_ext_mess](https://github.com/user-attachments/assets/09ff8fd9-1ec0-438a-ac7a-e97a28abaca9)

I visualized data from Kafka Topic expedia_ext with KSQL. 
I chose to apply a portforwarding to the ksqldb pod until I execute all the APi calls:


First I created a stream from expedia_ext topic:

```python
PS C:\data_eng\házi\7\ci_cd> make create_stream
curl -X POST http://localhost:8088/ksql \
-H "Content-Type: application/vnd.ksql.v1+json; charset=utf-8" \
-d @ksql/create_stream.json
[{"@type":"currentStatus","statementText":"CREATE STREAM EXPEDIA_STREAM (ID BIGINT, HOTEL_ID BIGINT, STAY_CATEGORY STRING) WITH (CLEANUP_POLICY='delete', KAFKA_TOPIC='expedia_ext', KEY_FORMAT='KAFKA', VALUE_FORMAT='JSON');","commandId":"stream/`EXPEDIA_STREAM`/create","commandStatus":{"status":"SUCCESS","message":"Stream created","queryId":null},"commandSequenceNumber":0,"warnings":[]}]
```

Then created table from stream as select query:

```python
PS C:\data_eng\házi\7\ci_cd> make create_table
curl -X POST http://localhost:8088/ksql \
-H "Content-Type: application/vnd.ksql.v1+json; charset=utf-8" \
-d @ksql/create_table.json
[{"@type":"currentStatus","statementText":"CREATE TABLE HOTELS_COUNT WITH (CLEANUP_POLICY='compact', KAFKA_TOPIC='HOTELS_COUNT', PARTITIONS=3, REPLICAS=3, RETENTION_MS=604800000) AS SELECT\n  EXPEDIA_STREAM.STAY_CATEGORY STAY_CATEGORY,\n  COUNT(EXPEDIA_STREAM.HOTEL_ID) HOTELS_AMOUNT,\n  COUNT_DISTINCT(EXPEDIA_STREAM.HOTEL_ID) DISTINCT_HOTELS\nFROM EXPEDIA_STREAM EXPEDIA_STREAM\nGROUP BY EXPEDIA_STREAM.STAY_CATEGORY\nEMIT CHANGES;","commandId":"table/`HOTELS_COUNT`/create","commandStatus":{"status":"SUCCESS","message":"Created query with ID CTAS_HOTELS_COUNT_1","queryId":"CTAS_HOTELS_COUNT_1"},"commandSequenceNumber":2,"warnings":[]}]
```

Retrieved the total number of hotels (hotel_id) and the number of distinct hotels per category:

```python
PS C:\data_eng\házi\7\ci_cd> make select_hotels
curl -X POST http://localhost:8088/query \
-H "Content-Type: application/vnd.ksql.v1+json; charset=utf-8" \
-d @ksql/select_hotels.json
{"queryId":"transient_HOTELS_COUNT_2406405773191826999","columnNames":["STAY_CATEGORY","HOTELS_AMOUNT","DISTINCT_HOTELS"],"columnTypes":["STRING","BIGINT","BIGINT"]}
["Short stay",21046,2486]
["Long stay",51,51]
["Standard stay",2400,1542]
["Erroneous data",22,22]
["Standard extended stay",130,126]
["Long stay",55,55]
["Standard stay",2514,1582]
["Short stay",22026,2486]
["Erroneous data",24,24]
["Standard extended stay",138,135]
["Long stay",56,56]
["Standard stay",2563,1605]
["Short stay",22799,2486]
["Erroneous data",27,26]
["Standard extended stay",142,138]
["Long stay",58,58]
["Standard stay",2676,1645]
["Short stay",23486,2486]
["Standard extended stay",144,140]
["Erroneous data",28,27]
["Long stay",60,60]
["Standard stay",2809,1688]
["Short stay",24605,2486]
["Standard extended stay",155,151]
["Long stay",63,62]
["Standard stay",2942,1737]
["Short stay",25774,2486]
["Erroneous data",29,28]
["Standard extended stay",157,152]
["Short stay",26885,2486]
["Long stay",68,67]
["Standard stay",3072,1777]
["Standard extended stay",164,158]
["Erroneous data",34,33]
["Short stay",27877,2486]
["Long stay",74,72]
["Standard stay",3159,1802]
["Erroneous data",36,35]
["Standard extended stay",169,163]
["Short stay",28842,2486]
["Erroneous data",38,37]
["Standard extended stay",175,169]
["Long stay",76,74]
["Standard stay",3240,1822]
["Short stay",29199,2486]
["Erroneous data",40,39]
["Standard extended stay",176,170]
["Standard stay",3297,1841]
["Long stay",80,78]
["Short stay",30071,2486]
["Erroneous data",41,40]
["Standard extended stay",182,176]
["Long stay",82,79]
["Standard stay",3419,1870]
["Short stay",31225,2486]
["Erroneous data",44,43]
["Standard extended stay",186,179]
["Long stay",86,83]
["Standard stay",3536,1899]
["Short stay",32506,2486]
["Erroneous data",47,46]
["Standard extended stay",190,182]
["Long stay",88,85]
["Standard stay",3671,1948]
["Short stay",33616,2486]
["Standard extended stay",197,189]
["Erroneous data",48,47]
["Long stay",91,88]
["Standard stay",3795,1964]
```

Finally I checked the Flow chart in the UI:

![cicd_flow](https://github.com/user-attachments/assets/f3c7c252-c864-4489-8f6b-ba01db674029)
