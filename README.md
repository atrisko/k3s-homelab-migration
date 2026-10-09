# Cloud-to-Bare-Metal: K3s Infrastructure PoC

This repository contains an automated Proof-of-Concept (PoC) for deploying a **K3s Kubernetes cluster** on **Debian 13 (Trixie)**. 

The primary architectural goal is achieving strict separation between **infrastructure provisioning (Phase 1)** and **system configuration & workload orchestration (Phase 2 & Phase 3)**, serving as a functional blueprint for a bare-metal homelab migration.

---

## Architecture at a Glance

* **Phase 1 (Infrastructure Provisioning):** Managed via **Terraform** on AWS (ephemeral testbed: VPC, Subnet, Security Group, EC2, EBS) or hypervisor/bare-metal installation.
* **Phase 2 (OS Baseline & Storage Configuration):** Managed declaratively via **Ansible** (storage formatting, mounting, OS hardening, base dependencies).
* **Phase 3 (Cluster Bootstrap & Runtime Orchestration):** Deployed via **Ansible** and managed autonomously at runtime by **K3s** (K3s control-plane/agents, Traefik ingress, manifests, Helm charts).
* **Bare-Metal Portability:** By isolating operating system configuration and Kubernetes deployment into Ansible, the entire Phase 2 & Phase 3 workflow runs identically on physical bare-metal nodes once Debian is installed.

---

## Deployment Targets & Multi-Platform Strategy

The infrastructure and provisioning workflow is strictly platform-agnostic, separating infrastructure declaration from application orchestration:

| Layer | AWS Cloud PoC (`eu-central-1`) | RemoteLab (Hyper-V Hypervisor) | Bare-Metal Target (Homelab) |
| :--- | :--- | :--- | :--- |
| **Purpose** | IaC validation, cloud networking, ephemeral PoC | Staging, load testing, migration rehearsal | Production runtime environment |
| **Compute** | EC2 (`t3.micro` for base tests, `t3.large` for full load) | Debian Gen2 VM (dedicated vCPUs, dynamic RAM) | Physical Debian 13 node |
| **Storage** | AWS EBS (`gp3`, 10 GB PoC) | Virtual Hard Disk (`.vhdx`, dynamically sized) | Dedicated NVMe / SATA SSD pools |
| **Provisioning** | Terraform + Ansible | Hyper-V Host / PowerShell + Ansible | ISO / Cloud-Init + Ansible |
| **Cost Profile** | Pay-as-you-go (~0.08 $/hr for load testing) | Zero marginal cost (continuous runtime) | Fixed local hardware cost |

### Orchestration Principle
Ansible plays and roles target the abstract OS layer (`Debian 13`). Whether executed against an AWS EC2 instance via the generated `ssh_config`, a VM in the RemoteLab, or physical bare metal, the provisioning baseline, storage mounts, and K3s bootstrap remain idempotent and reproducible.

---

## GitOps & CI/CD Pipeline (GitHub Actions)

To transition from local execution to declarative GitOps, the **Ansible Control Node** is migrated into a GitHub Actions CI/CD pipeline.

```mermaid
flowchart LR
    Dev([Developer / Git Push]) -->|Branch: main<br/>Path: ansible/**| GHA[GitHub Actions Runner<br/>*Ephemeral Control Node*]
    Manual([Manual Trigger<br/>workflow_dispatch]) --> GHA

    subgraph Pipeline [CI/CD Workflow Phases]
        Lint[1. Lint & Syntax<br/>ansible-lint] --> DryRun[2. Idempotency Check<br/>ansible-playbook --check]
        DryRun --> Apply[3. Configuration Rollout<br/>ansible-playbook site.yaml]
    end

    GHA --> Pipeline
    Pipeline -->|SSH via In-Memory Agent| Node[Debian 13 Target Node<br/>AWS EC2 / Bare Metal]
    
    subgraph Target [Target Node Architecture]
        Node -->|Declares State & Bootstraps| K3sEngine[K3s Kubernetes Engine]
        K3sEngine -->|Continuous Autonomous Runtime| Containers[Containerized Workloads & Traefik]
    end
```

### 1. Architecture & Ephemeral Control Node
* **Push-based GitOps:** The GitHub Actions runner acts as a disposable, ephemeral Ansible Control Node. Changes pushed to the repository automatically trigger the desired configuration state against the target host.
* **Separation of Concerns:**
  * **Ansible (Declarative Configuration):** Enforces desired system state idempotently (OS hardening, disk partitioning/mounting, kernel parameters, K3s installation, baseline manifests).
  * **K3s (Autonomous Runtime):** Manages continuous container lifecycle, self-healing, health probes, service discovery, and Traefik ingress routing independently of CI/CD runtime.

### 2. Secret- & Key-Management
Security adheres to the **Principle of Least Privilege (PoLP)** without persisting credentials on runners:
* **In-Memory SSH Agent:** Target node SSH credentials (`SSH_PRIVATE_KEY`) are stored as encrypted GitHub Repository Secrets (or injected dynamically via 1Password Service Account Action) and loaded exclusively into memory during runner execution via `webfactory/ssh-agent@v0.9.0`.
* **Zero Disk Persistence:** No private keys or long-lived authentication tokens are written to runner storage. Host keys are strictly checked or passed via parameterized SSH known_hosts injection.

### 3. Workflow Triggers & Execution Stages
* **Triggers:**
  * `push` to `main` (restricted to changes within `ansible/**`).
  * `workflow_dispatch` for manual dry-runs and parameter-driven deployments.
* **Pipeline Stages:**
  1. **Validation & Linting:** Executes `ansible-lint` and YAML validation to verify playbooks and roles against best practices.
  2. **Dry Run / Diff (Optional):** Runs `ansible-playbook -i inventory --check --diff` to preview state deviations before rollout.
  3. **Playbook Execution:** Executes `ansible-playbook -i <inventory> site.yaml` to enforce the target state.

### 4. Transition to Bare-Metal Homelab
The GitOps pipeline is architected to transition seamlessly from the AWS cloud PoC to local physical hardware:
* **Networking & Reachability:** Targets behind residential NAT/firewalls can be reached securely without open ingress ports via:
  * **Mesh VPN Overlay (e.g., Tailscale / WireGuard):** Ephemeral GitHub runner connects to the Tailscale tailnet before executing Ansible.
  * **Self-Hosted Runner:** Running an isolated GitHub Actions runner directly within the homelab DMZ/LAN.
* **Inventory Switching:** Changing environments only requires selecting the corresponding Ansible inventory group (`aws_poc` vs. `bare_metal`), keeping all underlying playbooks identical.

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

1. **Provision Infrastructure (Phase 1):**
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