variable "tailscale_auth_key" {
  sensitive = true
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