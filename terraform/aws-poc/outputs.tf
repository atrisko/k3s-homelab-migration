output "instance_public_ip" {
  description = "Die öffentliche IP-Adresse des K3s Servers"
  value       = aws_instance.k3s_server.public_ip
}

output "admin_cidr" {
  description = "Whitelisted IP CIDR for administrative access (SSH, K8s API)"
  value       = local.admin_cidr
}