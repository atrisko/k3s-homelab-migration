output "instance_public_ip" {
  description = "Die öffentliche IP-Adresse des K3s Servers"
  value       = aws_instance.k3s_server.public_ip
}