# 1. Main Network (Virtual Private Cloud)
resource "aws_vpc" "k3s_vpc" {
  cidr_block           = "10.0.0.0/16" # Large private network (65,536 IPs)
  enable_dns_hostnames = true          # Required to assign AWS DNS hostnames to instances
  tags                 = { Name = "k3s-poc-vpc" }
}

# 2. Internet Gateway (Enables inbound/outbound internet traffic)
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.k3s_vpc.id
}

# 3. Public Subnet (Where our K3s server will reside)
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.k3s_vpc.id
  cidr_block              = "10.0.1.0/24" # 256 IPs allocated from the VPC
  map_public_ip_on_launch = true          # Automatically assign a public IP to the instance
}

# 4. Route Table (Directs internet-bound traffic to the Gateway)
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.k3s_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# 5. Firewall (Security Group)
resource "aws_security_group" "k3s_sg" {
  name        = "k3s_allow_traffic"
  description = "Allow SSH, Web traffic, and K8s API access"
  vpc_id      = aws_vpc.k3s_vpc.id

  # Inbound traffic (Ingress)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # SSH from anywhere. In production, restrict this to your own IP!
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # HTTP for Traefik
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # HTTPS for Traefik
  }

  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # K8s API port for local kubectl access
  }

  # Outbound traffic (Egress) - Allow all outbound traffic (e.g., for OS updates, image pulls)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}