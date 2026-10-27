# Fetch the latest Debian 13 (Trixie) image from the official Debian project
data "aws_ami" "debian" {
  most_recent = true
  owners      = ["136693071363"] # Official Debian AWS account ID

  filter {
    name   = "name"
    values = ["debian-13-amd64-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# Upload the dedicated public key to AWS EC2
resource "aws_key_pair" "k3s_key" {
  key_name   = "k3s-poc-key"
  public_key = file(pathexpand(var.ssh_public_key_path))

  tags = {
    Name = "k3s-poc-key"
  }
}

# The virtual machine (K3s Node)
resource "aws_instance" "k3s_server" {
  ami                    = data.aws_ami.debian.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.k3s_sg.id]
  lifecycle {
    ignore_changes = [
      ami
    ]
  }

  # Enforce IMDSv2 to protect against SSRF metadata extraction
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  # Encrypt root operating system volume
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 10
    encrypted             = true
    delete_on_termination = true
  }

  # IMPORTANT: No userdata script here! 
  # OS configuration and K3s installation will be handled by Ansible (Day 1 Ops).

  # Attach the provisioned SSH key pair for remote access and Ansible orchestration
  key_name = aws_key_pair.k3s_key.key_name

  tags = {
    Name = "K3s-PoC-Server"
  }
}

# Additional 10 GB disk (Simulates the future mergerfs/SnapRAID storage pool)
resource "aws_ebs_volume" "data_volume" {
  availability_zone = aws_instance.k3s_server.availability_zone
  size              = 10
  type              = "gp3"
  encrypted         = true
}


# Attach the EBS volume to the EC2 instance
resource "aws_volume_attachment" "ebs_att" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data_volume.id
  instance_id = aws_instance.k3s_server.id
}

# Automatically write a dedicated SSH config file on apply
resource "local_file" "ssh_config" {
  content = <<-EOF
    Host aws-k3s-poc
        HostName ${aws_instance.k3s_server.public_ip}
        User admin
        IdentityFile ${trimsuffix(pathexpand(var.ssh_public_key_path), ".pub")}
        IdentitiesOnly yes
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
  EOF

  filename        = "${path.module}/ssh_config"
  file_permission = "0600"
}

# Generate the Ansible inventory file
resource "local_file" "ansible_inventory" {
  content = <<-EOF
    all:
      children:
        k3s_cluster:
          hosts:
            aws-k3s-poc:
              ansible_user: admin
              ansible_ssh_common_args: '-F ${abspath(path.module)}/ssh_config'
              node_ipv4: "${aws_instance.k3s_server.private_ip}"
              data_disk_device: "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.data_volume.id, "-", "")}"
  EOF

  filename        = "${path.module}/../../ansible/inventory/hosts.yaml"
  file_permission = "0644"
}
