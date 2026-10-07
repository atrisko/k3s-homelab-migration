# K3s Homelab Migration & Infrastructure as Code

This repository documents my transition from an appliance-based homelab (Unraid) to a fully declarative, GitOps-driven Kubernetes (K3s) environment. 

The project serves as both a functional homelab upgrade and a hands-on learning path for modern DevOps practices, Infrastructure as Code (IaC), configuration management, and container orchestration.

## 🎯 Project Goals & Roadmap

* **Phase 1: Cloud Proof of Concept (Current)** 
  Provisioning the foundational architecture in AWS using Terraform, and automating the OS configuration and K3s bootstrap process using Ansible. This validates the setup in a risk-free environment.
* **Phase 2: Workload Migration** 
  Converting existing Docker Compose workloads (32+ containers) into declarative Kubernetes manifests.
* **Phase 3: Bare Metal Cutover** 
  Reusing the Ansible playbooks to deploy Debian/Ubuntu on the physical homelab hardware, configure `mergerfs` and `SnapRAID` for storage management, and bootstrap the local K3s cluster.

## 🛠️ Technology Stack & Separation of Concerns

* **Day 0 - Provisioning:** Terraform & AWS (EC2, VPC, EBS)
* **Day 1 - Configuration:** Ansible (OS setup, storage mounts, K3s installation)
* **Day 2 - Orchestration:** Kubernetes (K3s) & Traefik (Ingress)
* **Storage Backup/Parity:** mergerfs & SnapRAID

## 🚀 Getting Started (AWS PoC)

Detailed documentation for the AWS Proof of Concept can be found in [`docs/01-aws-poc.md`](docs/01-aws-poc.md).

### 1. Infrastructure Provisioning
```bash
cd terraform/aws-poc
terraform init
terraform apply