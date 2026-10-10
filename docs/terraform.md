# Terraform Infrastructure Documentation

This document covers the technical details, resource mappings, and lifecycle decisions implemented in the AWS Proof-of-Concept environment (`terraform/aws-poc`).

---

## 1. Network Topology (`network.tf`)

Rather than relying on the AWS Default VPC, the environment provisions an isolated, dedicated network stack:

* **VPC (`aws_vpc.k3s_vpc`):**
  * CIDR block: `10.0.0.0/16` (65,536 private IPs) for future subnet expansion and container IP demand.
  * `enable_dns_hostnames = true` ensures internal private DNS resolution.
* **Subnet (`aws_subnet.public_subnet`):**
  * CIDR block: `10.0.1.0/24`.
  * `map_public_ip_on_launch = true` dynamically allocates a public IPv4 to compute instances upon creation.
* **Internet Gateway & Route Table (`aws_internet_gateway`, `aws_route_table`):**
  * Default route (`0.0.0.0/0`) pointed to the IGW to establish outbound/inbound internet routing.

### Stateful Firewall (`aws_security_group.k3s_sg`)

* **Ingress:**
  * Port `22` (TCP): SSH access for remote management and Ansible execution.
  * Ports `80` & `443` (TCP): HTTP/HTTPS traffic targeting the Traefik ingress controller.
  * Port `6443` (TCP): Kubernetes API server access for remote `kubectl`.
* **Egress:**
  * Protocol `-1` across all ports to allow package updates (`apt`), container runtime retrieval, and image pulling.
  * *Note on Stateful Inspection:* Return traffic for established outbound requests is allowed automatically by AWS connection tracking.

---

## 2. Compute and Storage (`main.tf`)

### Dynamic AMI Discovery (`data "aws_ami.debian"`)

Instead of hardcoding AMI IDs, Terraform queries the official Debian project account (`owner: 136693071363`) for the latest stable Debian 13 (Trixie) amd64 image using regex filters.

### Decoupled Storage Architecture

The deployment deliberately separates root storage from application data:

1. **Root Block Device (8 GiB):** Ephemeral root volume holding the base Debian OS and system packages.
2. **Data Volume (`aws_ebs_volume.data_volume` - 10 GiB, gp3):** Dedicated block storage attached at `/dev/sdf` (exposed to the Debian Nitro guest kernel as `/dev/nvme1n1`).
3. **Volume Attachment (`aws_volume_attachment.ebs_att`):** Manages the logical attachment between EC2 and EBS.

> **Lifecycle Strategy:** For this PoC, `prevent_destroy` is intentionally omitted. Destroying the EBS volume alongside the instance forces Ansible to handle unformatted, raw disk initialization and filesystem creation (`ext4`) on every deployment, ensuring complete idempotency.

---

## 3. Access Management & Local SSH Automation

To adhere to the **Principle of Least Privilege (PoLP)** and isolate identity boundaries, the infrastructure uses a dedicated Ed25519 key pair instead of shared administrative credentials:

1. **Key Provisioning (`aws_key_pair.k3s_key`):**
   * Uploads the public key specified via the `ssh_public_key_path` variable.
   * Injected into the Debian instance via cloud-init for the default `admin` user.

2. **Automated Runtime SSH Config (`local_file.ssh_config`):**
   * Because EC2 instances receive dynamic public IPs across `apply`/`destroy` cycles, Terraform automatically generates a local OpenSSH client configuration file (`ssh_config`).
   * The generated file maps the alias `aws-k3s-poc` to the newly provisioned public IP, disables host-key collisions (`UserKnownHostsFile /dev/null`, `StrictHostKeyChecking no`), points `IdentityFile` to the corresponding private key (`trimsuffix(..., ".pub")`), and enforces `IdentitiesOnly yes`.
   * **Security Notice:** The generated `ssh_config` file contains local runtime data and is excluded from source control via `.gitignore`.

### Connecting to the Host

```bash
# Connect using the generated runtime configuration
ssh -F ssh_config aws-k3s-poc
```

---

## 4. Terraform State & Execution Notes

* **Dependency Graph:** Changes to compute attributes (e.g., AMI upgrade) trigger instance replacement while maintaining independent EBS volume definitions.
* **Teardown Command:**
  ```bash
  terraform destroy
  ```