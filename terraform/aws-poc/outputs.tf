output "instance_public_ip" {
  description = "Public IPv4 address of the K3s server instance"
  value       = aws_instance.k3s_server.public_ip
}

output "admin_cidr" {
  description = "Whitelisted IP CIDR for administrative access (SSH, K8s API)"
  value       = local.admin_cidr
}

output "data_volume_id" {
  description = "EBS volume ID for the secondary data disk"
  value       = aws_ebs_volume.data_volume.id
}

output "data_disk_device" {
  description = "Persistent /dev/disk/by-id path for EBS data volume (AWS Nitro NVMe)"
  value       = "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.data_volume.id, "-", "")}"
}