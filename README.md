# Cloud-to-Bare-Metal: K3s Infrastructure PoC

This repository contains an automated Proof-of-Concept (PoC) for deploying a **K3s Kubernetes cluster** on **Debian 13 (Trixie)**. 

The primary architectural goal is achieving strict separation between **cloud provisioning (Day 0)** and **system configuration (Day 1 & Day 2)**, serving as a functional blueprint for a bare-metal homelab migration.

---

## Architecture at a Glance

* **Day 0 (Infrastructure Provisioning):** Managed via **Terraform** on AWS (ephemeral testbed: VPC, Subnet, Security Group, EC2, EBS).
* **Day 1 & 2 (OS Configuration & Workloads):** Managed via **Ansible** (storage formatting, mounting, K3s installation, Traefik ingress).
* **Bare-Metal Portability:** By isolating operating system configuration into Ansible, the entire Day 1/2 workflow runs identically on physical bare-metal nodes once Debian is installed.

---

## Deployment Targets & Multi-Platform Strategy

The infrastructure and provisioning workflow is strictly platform-agnostic, separating infrastructure declaration from application orchestration:

| Layer | AWS Cloud PoC (`eu-central-1`) | RemoteLab (Hyper-V Hypervisor) |
| :--- | :--- | :--- |
| **Purpose** | IaC validation, cloud networking, ephemeral PoC | Staging, load testing, full stack migration rehearsal (32+ containers) |
| **Compute** | EC2 (`t3.micro` for base tests, `t3.large` for full load) | Debian Gen2 VM (dedicated vCPUs, expandable RAM) |
| **Storage** | AWS EBS (`gp3`, 10 GB PoC) | Virtual Hard Disk (`.vhdx`, dynamically sized) |
| **Provisioning** | Terraform + Ansible | Hyper-V Host / PowerShell + Ansible |
| **Cost Profile** | Pay-as-you-go (~0.08 $/hr for load testing) | Zero marginal cost (continuous runtime) |

### Orchestration Principle
Ansible plays and roles target the abstract OS layer (`Debian 13`). Whether executed against an AWS EC2 instance via the generated `ssh_config` or against a static IP in the Hyper-V RemoteLab, the provisioning baseline, storage-mounts, and K3s bootstrap remain identical.

---

## Repository Structure

```text
.
├── README.md               # Project entry point and high-level overview
├── docs/                   # Modular architecture and technical documentation
│   ├── terraform.md        # Detailed guide for AWS provisioning & lifecycle
│   └── ansible.md          # OS hardening, storage mounts, and K3s rollout (planned)
├── terraform/
│   └── aws-poc/            # Infrastructure-as-Code definitions (VPC, EC2, EBS)
└── ansible/                # Playbooks, roles, and inventory (in progress)
```

---

## Detailed Documentation

* [Terraform AWS Provisioning & Lifecycle Guide](docs/terraform.md)
* Architecture Decisions & Network Topology (`docs/architecture.md` - coming soon)
* Ansible Configuration & Storage Orchestration (`docs/ansible.md` - coming soon)

---

## Quickstart

### Prerequisites

* AWS CLI installed and configured (`~/.aws/credentials`)
* Terraform >= 1.5.0
* Dedicated SSH key pair (default: `~/.ssh/id_ed25519_aws_homelab.pub`)

### Run the PoC Cycle

1. **Provision Infrastructure:**
   ```bash
   cd terraform/aws-poc
   terraform init
   terraform apply
   ```

2. **Access the Node:**
   ```bash
   ssh -F ssh_config aws-k3s-poc
   ```

3. **Teardown & Cleanup:**
   To avoid ongoing cloud costs when finished testing:
   ```bash
   terraform destroy
   ```

---

## License

Distributed under the [MIT License](LICENSE).