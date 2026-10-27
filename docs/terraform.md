# Terraform Infrastructure Documentation

This document covers the technical architecture, security baselines, and resource mappings implemented in the AWS Proof-of-Concept environment (`terraform/aws-poc`).

---

## 1. Provider & Project Conventions (`providers.tf`, `variables.tf`)

* **Terraform Version Guard:** Enforces `required_version = ">= 1.5.0"`, AWS Provider `~> 5.0`, HTTP Provider `~> 3.4`, and Local Provider `~> 2.5` (Review 2 R2-11).
* **Global Tagging (`default_tags`):** All provisioned AWS resources automatically receive tags:
  * `Project = "k3s-homelab-poc"`
  * `ManagedBy = "terraform"`
* **Core Variables:**
  * `aws_region`: Deployment region (default: `"eu-central-1"`).
  * `aws_profile`: AWS CLI credentials profile (default: `"homelab"`).
  * `instance_type`: Virtual machine size (default: `"t3.small"`, low-cost instance providing 2 GB RAM for K3s + ArgoCD at ~0.10–0.20 € per 2–4 h test cycle).
  * `admin_cidr`: Whitelisted CIDR for administrative access. If null, dynamically discovered via `https://checkip.amazonaws.com` (validated with lifecycle `postcondition` ensuring HTTP 200).
  * `ssh_public_key_path`: Path to the dedicated Ed25519 key pair (default: `"~/.ssh/id_ed25519_aws_homelab.pub"`).

---

## 2. Network Topology & Perimeter Security (`network.tf`)

Rather than deploying into the AWS Default VPC, the environment creates an isolated network stack:

* **VPC (`aws_vpc.k3s_vpc`):**
  * CIDR block: `10.0.0.0/16` with `enable_dns_hostnames = true`.
* **Subnet (`aws_subnet.public_subnet`):**
  * CIDR block: `10.0.1.0/24` with `map_public_ip_on_launch = true` for dynamic public IPv4 allocation.
* **Internet Gateway & Route Table:**
  * Default route (`0.0.0.0/0`) directed to `aws_internet_gateway.igw`.

### Security Group Ingress / Egress Rules (`aws_security_group.k3s_sg`)

* **Ingress (Perimeter Defense - Review 2 R2-11):**
  * Port `22` (SSH): Restricted exclusively to operator IP (`local.admin_cidr`).
  * Port `6443` (Kubernetes API): Restricted exclusively to operator IP (`local.admin_cidr`).
  * Ports `80` (HTTP) & `443` (HTTPS): Restricted exclusively to operator IP (`local.admin_cidr`). Public access is closed since no internet-facing workloads are published in the PoC.
* **Egress:**
  * Protocol `-1` (all traffic allowed outbound) for OS package updates (`apt`), container image pulling, and Helm charts.

---

## 3. Compute, Storage & Security Controls (`main.tf`)

### Dynamic AMI Discovery & Lifecycle Guard
* **AMI Query (`data.aws_ami.debian`):** Discovers the latest official Debian 13 (Trixie) amd64 image from the Debian project account (`136693071363`).
* **AMI Replacement Guard (`lifecycle { ignore_changes = [ami] }`):** Prevents Terraform from destroying and replacing running instances when upstream Debian publishes a new point-release AMI.

### Compute Security Baseline
* **IMDSv2 Enforcement:**
  * `http_tokens = "required"`: Enforces session-oriented IMDSv2 metadata tokens, protecting the host against Server-Side Request Forgery (SSRF) credential extraction.
* **Zero User-Data:**
  * EC2 `user_data` is intentionally omitted. Operating system configuration and K3s provisioning are exclusively handled by Ansible (Day-1 operations).

### Decoupled Block Storage
* **Root Volume (10 GiB, gp3):** Encrypted root volume (`encrypted = true`) holding the Debian base OS, deleted automatically on instance termination (`delete_on_termination = true`).
* **Secondary Data Volume (`aws_ebs_volume.data_volume` - 10 GiB, gp3):**
  * Encrypted block volume (`encrypted = true`) attached as `/dev/sdf`.
  * Dedicated storage tier for K3s persistent volumes (`/mnt/appdata`).
  * Addressed on the host via the persistent udev path `/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_<vol_id>` to guarantee stability against Nitro NVMe controller enumeration flipping.

---

## 4. Local Automation & Ansible Bridge (`main.tf`, `outputs.tf`)

Terraform bridges infrastructure provisioning with Ansible automation by generating configuration files on `terraform apply`:

1. **SSH Client Configuration (`local_file.ssh_config`):**
   * Generates a local `ssh_config` (mode `0600`) aliasing `aws-k3s-poc` to the instance's public IP.
   * Configures `IdentitiesOnly yes`, points to the matching private key, and prevents host-key prompt collisions on disposable instances (`UserKnownHostsFile /dev/null`, `StrictHostKeyChecking no`).
2. **Dynamic Ansible Inventory (`local_file.ansible_inventory`):**
   * Automatically renders `ansible/inventory/hosts.yaml` referencing the generated SSH bridge (`-F ssh_config`) and the persistent `data_disk_device` path.
3. **Outputs (`outputs.tf`):**
   * `instance_public_ip`: Target server public IP.
   * `admin_cidr`: Active operator CIDR whitelist.
   * `data_volume_id`: Secondary EBS volume ID.
   * `data_disk_device`: Persistent `/dev/disk/by-id/...` device path for Ansible storage mounts.

---

## 5. Execution Guide

```bash
# 1. Initialize and review execution plan
terraform init
terraform plan

# 2. Provision infrastructure and generate Ansible configs
terraform apply

# 3. Connect via generated SSH alias
ssh -F ssh_config aws-k3s-poc

# 4. Teardown all resources (disposable test environment)
terraform destroy
```