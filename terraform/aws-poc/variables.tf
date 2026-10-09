variable "ssh_public_key_path" {
  description = "Path to the dedicated SSH public key for the K3s PoC"
  type        = string
  default     = "~/.ssh/id_ed25519_aws_poc.pub"
}