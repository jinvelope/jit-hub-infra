# shared/modules/cloudflared/connector/variables.tf

variable "namespace" {
  type    = string
  default = "cloudflared"
}

variable "create_namespace" {
  type    = bool
  default = true
}

variable "secret_name" {
  type    = string
  default = "cloudflared-token"
}

variable "tunnel_token" {
  type      = string
  sensitive = true
}