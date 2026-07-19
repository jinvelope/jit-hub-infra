terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
  }
}

# --- Providers -----------------------------------------------------------------
provider "cloudflare" { 
  api_token = var.cloudflare_api_token 
}

provider "kubernetes" { 
  config_path = "~/.kube/config" 
}

provider "helm" { 
  kubernetes { 
    config_path = "~/.kube/config" 
  } 
}

provider "kubectl" { 
  config_path = "~/.kube/config" 
}

# --- Variables -----------------------------------------------------------------
variable "cloudflare_api_token" {
  description = "Cloudflare API Token"
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID (도메인의 고유 ID)"
  type        = string
}

variable "cloudflare_account_id" {
  description = "Cloudflare Account ID"
  type        = string
}

variable "domain_name" {
  description = "연결할 외부 도메인 (unzipp.cloud)"
  type        = string
}
