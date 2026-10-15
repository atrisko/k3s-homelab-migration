variable "ssh_public_key_path" {
  description = "Path to the dedicated SSH public key for the K3s PoC"
  type        = string
  default     = "~/.ssh/id_ed25519_aws_poc.pub"
}

variable "admin_cidr" {
  description = "Whitelisted CIDR block for administrative access (SSH, K8s API). If null, dynamically queries checkip.amazonaws.com."
  type        = string
  default     = null
}