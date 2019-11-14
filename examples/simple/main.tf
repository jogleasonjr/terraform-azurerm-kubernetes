variable "client_id" {}
variable "client_secret" {}
variable "resource_group_name" {}
variable "location" {
    default = "eastus2"
}

module "simple" {
    source = "../../"

    name = "simple"
    resource_group_name = var.resource_group_name
    location = var.location
    kubernetes_version = "1.15.5"
    
    service_principal = {
        client_id = var.client_id
        client_secret = var.client_secret
    }
}
