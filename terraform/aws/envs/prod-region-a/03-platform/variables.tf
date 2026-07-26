variable "tailscale_auth_key" {
  sensitive = true
}


variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

variable "cloudflare_account_id" {
  type      = string
  sensitive = true
}

variable "cloudflare_zone_id" {
  type      = string
  sensitive = true
}

variable "domain_name" {
  type = string
}

variable "harbor_robot_user" {
  type      = string
  sensitive = true
}

variable "harbor_robot_pull_token" {
  type      = string
  sensitive = true
}

variable "harbor_registry_server" {
  type    = string
}