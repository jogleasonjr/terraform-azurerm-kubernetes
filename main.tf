terraform {
  required_version = ">= 0.12.6"
  required_providers {
    azurerm    = "~> 1.36.0"
    kubernetes = "~> 1.9.0"
  }
}

locals {
  default_agent_profile = {
    count               = 1
    vm_size             = "Standard_D2_v3"
    os_type             = "Linux"
    availability_zones  = null
    enable_auto_scaling = false
    min_count           = null
    max_count           = null
    type                = "VirtualMachineScaleSets"
    node_taints         = null
  }

  # Diagnostic settings
  diag_kube_logs = [
    "kube-apiserver",
    "kube-audit",
    "kube-controller-manager",
    "kube-scheduler",
    "cluster-autoscaler",
  ]
  diag_kube_metrics = [
    "AllMetrics",
  ]

  diag_resource_list = var.diagnostics != null ? split("/", var.diagnostics.destination) : []
  parsed_diag = var.diagnostics != null ? {
    log_analytics_id   = contains(local.diag_resource_list, "microsoft.operationalinsights") ? var.diagnostics.destination : null
    storage_account_id = contains(local.diag_resource_list, "Microsoft.Storage") ? var.diagnostics.destination : null
    event_hub_auth_id  = contains(local.diag_resource_list, "Microsoft.EventHub") ? var.diagnostics.destination : null
    metric             = contains(var.diagnostics.metrics, "all") ? local.diag_kube_metrics : var.diagnostics.metrics
    log                = contains(var.diagnostics.logs, "all") ? local.diag_kube_logs : var.diagnostics.metrics
    } : {
    log_analytics_id   = null
    storage_account_id = null
    event_hub_auth_id  = null
    metric             = []
    log                = []
  }
}

resource "azurerm_resource_group" "aks" {
  name     = var.resource_group_name
  location = var.location

  tags = var.tags
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                            = "${var.name}-aks"
  location                        = azurerm_resource_group.aks.location
  resource_group_name             = azurerm_resource_group.aks.name
  dns_prefix                      = var.name
  kubernetes_version              = var.kubernetes_version
  api_server_authorized_ip_ranges = var.api_server_authorized_ip_ranges
  node_resource_group             = var.node_resource_group
  enable_pod_security_policy      = var.enable_pod_security_policy

  agent_pool_profile {
    name            = "pool1"
    count           = 1
    vm_size         = "Standard_D1_v2"
    os_type         = "Linux"
    os_disk_size_gb = 30
  }

  agent_pool_profile {
    name            = "pool2"
    count           = 1
    vm_size         = "Standard_D2_v2"
    os_type         = "Linux"
    os_disk_size_gb = 30
  }

  service_principal {
    client_id     = var.service_principal.client_id
    client_secret = var.service_principal.client_secret
  }

  addon_profile {
    oms_agent {
      enabled = var.addons.oms_agent
      log_analytics_workspace_id = var.addons.oms_agent ? var.addons.oms_agent_workspace_id : null
    }

    kube_dashboard {
      enabled = var.addons.dashboard
    }

    azure_policy {
      enabled = var.addons.policy
    }
  }

  dynamic "linux_profile" {
    for_each = var.linux_profile != null ? [true] : []
    iterator = lp
    content {
      admin_username = var.linux_profile.username

      ssh_key {
        key_data = var.linux_profile.ssh_key
      }
    }
  }

  network_profile {
    network_plugin     = "azure"
    network_policy     = "azure"
    dns_service_ip     = cidrhost("10.1.2.0/24", 10)
    docker_bridge_cidr = "172.17.0.1/16"
    service_cidr       = "10.1.2.0/24"
    load_balancer_sku = "Standard"
  }
  
  tags = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "aks" {
  count                          = var.diagnostics != null ? 1 : 0
  name                           = "${var.name}-aks-diag"
  target_resource_id             = azurerm_kubernetes_cluster.aks.id
  log_analytics_workspace_id     = local.parsed_diag.log_analytics_id
  eventhub_authorization_rule_id = local.parsed_diag.event_hub_auth_id
  eventhub_name                  = local.parsed_diag.event_hub_auth_id != null ? var.diagnostics.eventhub_name : null
  storage_account_id             = local.parsed_diag.storage_account_id

  dynamic "log" {
    for_each = local.parsed_diag.log
    content {
      category = log.value

      retention_policy {
        enabled = false
      }
    }
  }

  dynamic "metric" {
    for_each = local.parsed_diag.metric
    content {
      category = metric.value

      retention_policy {
        enabled = false
      }
    }
  }
}

# Configure cluster

provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.aks.kube_admin_config.host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_admin_config.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_admin_config.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_admin_config.cluster_ca_certificate)
}

#
# Impersonation of admins
#

resource "kubernetes_cluster_role" "impersonator" {
  metadata {
    name = "impersonator"
  }

  rule {
    api_groups = [""]
    resources  = ["users", "groups", "serviceaccounts"]
    verbs      = ["impersonate"]
  }
}

resource "kubernetes_cluster_role_binding" "impersonator" {
  count = length(var.admins)

  metadata {
    name = "${var.admins[count.index].name}-administrator"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.impersonator.metadata.0.name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = var.admins[count.index].kind
    name      = var.admins[count.index].name
  }
}

#
# Container logs for Azure
#

resource "kubernetes_cluster_role" "containerlogs" {
  metadata {
    name = "containerhealth-log-reader"
  }

  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }
}

resource "kubernetes_cluster_role_binding" "containerlogs" {
  metadata {
    name = "containerhealth-read-logs-global"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.containerlogs.metadata.0.name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = "clusterUser"
  }
}

#
# Service accounts
#

resource "kubernetes_service_account" "sa" {
  count = length(var.service_accounts)

  metadata {
    name      = var.service_accounts[count.index].name
    namespace = var.service_accounts[count.index].namespace
  }

  automount_service_account_token = true
}

resource "kubernetes_cluster_role_binding" "sa" {
  count = length(var.service_accounts)

  metadata {
    name = var.service_accounts[count.index].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = var.service_accounts[count.index].role
  }

  subject {
    kind      = "ServiceAccount"
    name      = var.service_accounts[count.index].name
    namespace = var.service_accounts[count.index].namespace
  }
}

data "kubernetes_secret" "sa" {
  count = length(var.service_accounts)

  metadata {
    name      = kubernetes_service_account.sa[count.index].default_secret_name
    namespace = var.service_accounts[count.index].namespace
  }
}

#
# Tiller setup
#

resource "kubernetes_namespace" "tiller" {
  metadata {
    name = "tiller"
  }
}

module "tiller" {
  source = "github.com/avinor/terraform-kubernetes-tiller"
  #version = "3.2.0"

  tiller_version   = var.tiller_version
  tiller_namespace = kubernetes_namespace.tiller.metadata.0.name
}

resource "kubernetes_cluster_role" "tiller" {
  metadata {
    name = "tiller-access"
  }

  rule {
    api_groups = [""]
    resources  = ["pods/portforward"]
    verbs      = ["create"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get","list"]
  }
}

resource "kubernetes_role_binding" "tiller" {
  count = length(var.admins)

  metadata {
    name = "${var.admins[count.index].name}-tiller"
    namespace = "tiller"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.tiller.metadata.0.name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = var.admins[count.index].kind
    name      = var.admins[count.index].name
  }
}
