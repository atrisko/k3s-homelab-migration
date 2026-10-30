# 📋 Project Roadmap & Task List: K3s Homelab Migration

> **Status:** Phase 3 (K3s Bootstrap & Runtime) · State: October 2026  
> **References:** [README.md](../README.md) · [docs/adr/](adr/) · [docs/reviews/](reviews/) · [docs/testing/](testing/)  
> **Checkmarks** mean *verified*: an item is checked once its test cases have passed in a documented run ([docs/testing/runs/](testing/runs/)). Items whose tests failed are unchecked until a later run passes.

---

## 🏗️ Phase 1: AWS PoC Infrastructure (Terraform)

*Goal: Provide an ephemeral, cost-controlled testbed.*

- [x] Define VPC, subnets, and security groups (`terraform/aws-poc/network.tf`)
- [x] Provision EC2 Debian instance including EBS volumes (OS & app storage) (`terraform/aws-poc/main.tf`)
- [x] Configure 1Password SSH-Agent integration (`SSH_AUTH_SOCK`)
- [x] Generate dynamic `ssh_config` via Terraform for seamless login (`terraform/aws-poc/main.tf`)
- [x] Verify successful SSH connection via `ssh -F ssh_config aws-k3s-poc`
- [x] Provide Terraform output for persistent EBS volume ID (`outputs.tf`)
- [x] **Security & Hardening Baseline:**
  - [x] Restrict K8s API (port 6443) and SSH to operator IP (`admin_cidr`) instead of `0.0.0.0/0`
  - [x] AMI Lifecycle Guard: `lifecycle { ignore_changes = [ami] }` prevents instance replacement on upstream Debian AMI updates
  - [x] Enforce IMDSv2 (`metadata_options { http_tokens = "required" }`) against SSRF attacks
  - [x] Encrypt EBS root volume & secondary data disk (`encrypted = true`)
  - [x] Terraform hygiene: enforce `required_version`, variables for region/profile & global `default_tags`
  - [ ] Optional: Set up AWS Budget Alert (`aws_budgets_budget`) with email notification as cost guardrail

---

## ⚙️ Phase 2: Ansible Baseline Setup (Local Control Node)

*Goal: Structure server configuration management as code.*

- [x] **Configuration as code:** All node configuration is applied from this repository by a single playbook (`site.yaml`). The target environment is selected via inventory, role parameters are overridable per inventory, and required collections are declared in `requirements.yaml`.
- [x] **AWS connectivity:** Ansible reaches the AWS node through the Terraform-generated SSH config without manual setup.
- [ ] **Hardened base system (ADR-0004, ADR-0005):** SSH accepts key-based logins for the automation user only. Kernel parameters enforce anti-spoofing (loose-mode `rp_filter` for CNI compatibility), disable redirects and restrict kernel information leaks; uncommon filesystems and network protocols cannot be loaded. The journal is size-capped against Kubernetes DiskPressure, time is NTP-synchronized, security updates are installed automatically, and iSCSI/NFS client tooling is present.
- [x] **Non-interactive automation:** After the initial run, the automation user executes privileged tasks without a password prompt; no plaintext passwords are stored.
- [x] **Persistent IPv6 ULA (ADR-0001):** The static ULA is active immediately after provisioning, without network interruption, and persists across reboots.
- [x] **Appdata volume:** The data volume is mounted at the appdata path and identified by a stable device ID, independent of kernel device naming. The node still boots if the disk is missing; provisioning aborts if no data device is declared.

---

## 🚢 Phase 3: K3s & Core Platform Bootstrap (Current Phase)

*Goal: Install container orchestration runtime and bootstrap initial services.*

- [x] **K3s runtime (dual-stack, ADR-0001, R2-3):** K3s runs as an enabled systemd service with dual-stack node, pod and service networking. Node IPs are declared explicitly instead of being inferred from DHCP. Provisioning aborts before installation if the ULA or the appdata mount is missing.
- [ ] **Reproducible installation (R2-6):** The K3s installer is pinned to the declared version and integrity-verified before execution. Repeated playbook runs, including after a reboot, report no changes; an upgrade only happens when the declared version differs. Configuration changes take effect without manual restarts.
- [x] **Persistent storage (R2-1):** Persistent volumes land on the dedicated appdata volume, never on the root disk. K3s does not run without the appdata volume, nothing reaches the root disk while it is missing, and a corrupted appdata filesystem keeps K3s down instead of starting on damaged data.
- [x] **GitOps bootstrap (R2-2, R2-9):** Argo CD is installed declaratively at a pinned, supported 3.x chart version and continuously syncs the smoke-test workload (Caddy) from the public repository, including self-heal. Deleting the root application never cascades into workload or PVC deletion.
- [x] **Remote API access (ADR-0007):** The Kubernetes API is reachable only from `admin_cidr` or via SSH port forwarding; additional TLS SANs can be declared per environment.
- [ ] **IPv6 under forwarding (R2-4, R2-5):** The node keeps its static ULA and its SLAAC addresses across reboots while IPv6 forwarding is enabled. Exactly one network stack (ifupdown or netplan) carries the ULA configuration; provisioning fails fast if neither is active.
- [x] **Host access (R2-7):** Persistent nodes (RemoteLab, bare metal) are reached with standard host key verification; relaxed checking is limited to the ephemeral AWS node.
- [x] **Kernel security updates (R2-8, ADR-0004):** Debian security updates, including kernel updates, are installed automatically and followed by a reboot in the 03:00 window.
- [x] **AWS perimeter (R2-11):** All inbound traffic to the AWS node (SSH, API, HTTP/S) is restricted to the operator IP; a failed IP lookup aborts the Terraform run instead of producing an open rule.
- [ ] **Ingress & MetalLB Network Preparation (VLAN 30):**
  - [ ] Disable K3s ServiceLB (`disable: [servicelb]` in `config.yaml`) to prevent conflicts with MetalLB
  - [ ] Define MetalLB L2-AddressPool for VLAN 30 (`10.55.64.200 - 10.55.64.249`) (Traefik .200, Pi-hole .201, Omada .202)
  - [ ] Configure Traefik service with `externalTrafficPolicy: Local` (client IP preservation without SNAT)
  - [ ] Secure Traefik Ingress Controller with `forwardedHeaders.trustedIPs` pointing to Caddy (`10.55.192.10/32`, `fd85:cc6d:b16f:70::10/128`)
- [ ] Securely export kubeconfig to local workstation (without committing to Git or storing unprotected)
- [ ] Decide on GitOps secrets management strategy (e.g. External Secrets Operator + 1Password or SOPS + age) – required before Phase 6
- [ ] *Optional:* Prepare Intel GPU Device Plugin for hardware transcoding in K3s
- [ ] *Optional:* Set up K9s on control node for cluster inspection

---

## 🤖 Phase 4: CI/CD & Code Quality (GitHub Actions)

*Goal: Automate testing, linting, and validation pipelines.*

- [ ] Define pipeline logic: syntax check & linting for Ansible playbooks (`ansible-lint`, `yamllint`)
- [ ] Establish local pre-commit hooks (`ansible-lint`, `terraform fmt`, `gitleaks`)
- [ ] **Runner Security Strategy:**
  - [ ] Public repository safety: avoid unauthenticated self-hosted runners with direct LAN/SSH access
  - [ ] Restrict automated CI pipelines to linting & dry-run checks (`--check --diff`)
- [ ] Configure GitHub repository secrets for SSH authentication in AWS PoC
- [ ] **Automated Dependency Updates (Renovate Bot):**
  - [ ] Create `.github/renovate.json` & integrate GitHub App
  - [ ] Version tracking for K3s (`k3s_version` in `defaults/main.yaml`) via regex manager
  - [ ] Helm chart tracking for ArgoCD (`argocd_chart_version`)
  - [ ] Container image tracking for Kubernetes manifests (`k8s/**`)
  - [ ] Automated PRs with changelogs for staging validation in RemoteLab
- [ ] Ephemeral cloud teardown test (`terraform destroy` and complete rebuild validation via pipeline)

---

## 🧪 Phase 4.5: RemoteLab Staging Environment (Hyper-V VM)

*Goal: Validate real-world LAN networking, storage persistence, and ingress without bare-metal risk.*

- [x] ADR-0002: Dedicated RemoteLab staging layer adopted
- [x] Configure inventory `inventory/remotelab.yaml` & SCSI WWID storage addressing
- [x] RemoteLab VM provisioned (Debian 13) and configured via `site.yaml`; a checkpoint of the fresh install allows clean bootstrap tests
- [ ] Validate dual-stack behavior with real router/SLAAC + static ULA in home network
- [ ] Verify 24-hour SLAAC stability under IPv6 forwarding (`accept_ra = 2` verification)
- [ ] **Caddy $\rightarrow$ Traefik Ingress & Header Staging Test (ADR-0003):**
  - [ ] Test Caddy reverse proxy forwarding to Traefik LoadBalancer IP
  - [ ] Verify header propagation (`X-Forwarded-For`, `X-Real-IP`) & Traefik `trustedIPs` on test workload
  - [ ] Validate MetalLB L2-AddressPool in local test subnet
  - [ ] Test passwordless sudo for Ansible user (`/etc/sudoers.d/10-ansible`)
- [x] Conduct idempotency & reboot audit:
  - [x] Second playbook run reports `changed=0`
  - [x] K3s survives host reboot cleanly
  - [x] Detached storage reboot test: verify K3s service fails safely without polluting root disk

---

## 🖥️ Phase 5: Bare-Metal Foundation (The Hardware Platform)

*Goal: Deploy the validated architecture onto physical hardware – cleanly isolated from production data.*

- [ ] Prepare physical hardware & install base Debian 13 on system SSD
- [ ] **Decoupled 2-Tier Storage Setup for Base System:**
  - [ ] **Tier 1 (OS):** Dedicated SATA SSD for Debian 13 base system (disposable, protects from I/O wear)
  - [ ] **Tier 2 (Appdata & K3s Runtime, ADR-0009):** 1 TB M.2 NVMe as degraded mdraid RAID1 (`missing` member) → LVM (`vg_appdata`) → ext4
    - [ ] Online mirror preparation: attach second M.2 later via `mdadm --add` (no reformat, no downtime); member partitions sized slightly below disk capacity
    - [ ] K3s I/O decoupling: dedicated LVs for `data-dir: /mnt/appdata/k3s` (containerd, pod overlays, SQLite WAL) and `default-local-storage-path: /mnt/appdata/storage`
    - [ ] Cache & Ingest: dedicated LV `/mnt/appdata/ingest` (LV size acts as quota) for staging ingest prior to array offloading
    - [ ] Keep ~30–40 % of the VG unallocated; grow LVs online via `lvextend -r`
    - [ ] Array monitoring (`mdadm --monitor` / node-exporter `mdadm` collector) and `fstrim.timer`
    - [ ] Extend K3s storage guard (`RequiresMountsFor`) to all Tier-2 mount points
- [ ] **Network & DMZ Isolation (VLAN 30 & VLAN 70):**
  - [ ] Configure 802.1q VLAN trunking on physical network interface via Ansible
  - [ ] Assign host interface to VLAN 30 (`10.55.64.10` / `fd85:cc6d:b16f:30::10`)
  - [ ] Unnumbered Linux bridge (`br70`) on tagged subinterface (`<nic>.70`) without IPv4 for KVM DMZ passthrough
  - [ ] Host isolation: disable IPv6 link-local on DMZ bridge & subinterface (`net.ipv6.conf.br70.disable_ipv6 = 1`)
- [ ] **KVM Hypervisor & Caddy VM (DMZ Ingress per ADR-0003):**
  - [ ] Install KVM/QEMU & libvirt packages on Debian
  - [ ] Declaratively provision Caddy VM (VLAN 70: `10.55.192.10`, bound to `br70`)
  - [ ] Deploy Caddyfile for automated Let's Encrypt TLS termination & reverse proxy to Traefik (`10.55.64.200`)
- [ ] Execute `os_base` and `k3s_install` roles on bare metal
- [ ] Add bare-metal host to Ansible inventory (`inventory/production.yaml`)
- [ ] Execute playbook against physical system (target: clean, running K3s base platform without production workloads)

---

## 🚀 Phase 6: GitOps Workload Migration & Secrets Management

*Goal: Manage container workloads and application secrets declaratively via GitOps.*

- [x] Install ArgoCD via Ansible HelmChart CRD in cluster (Phase 3 PoC)
- [ ] Finalize repository structure for workloads (`k8s/bootstrap/`, `k8s/infra/`, `k8s/apps/`)
- [ ] Set initial ArgoCD admin password declaratively (e.g. via Ansible Vault or Secrets Operator)
- [ ] Deploy secrets provider in cluster (e.g. External Secrets Operator with 1Password Connect / Service Account)
- [ ] **Dual-Stack Validation:** Verify ArgoCD pods obtain valid dual-stack IPv4/IPv6 pod IPs upon cluster launch
- [ ] App-of-Apps validation: establish root Application pointing to `k8s/apps/`, verify automatic sync and drift correction (self-healing)
- [ ] **Standard Monitoring Stack via GitOps (`k8s/infra/monitoring/`):**
  - [ ] Deploy `kube-prometheus-stack` Helm chart via ArgoCD:
    - [ ] **Prometheus Operator:** Central metrics collection for cluster, pods, and control plane
    - [ ] **Node-Exporter:** Host resource metrics (CPU, RAM, NVMe/HDD I/O, network)
    - [ ] **Kube-State-Metrics:** Cluster object health (pod restarts, CrashLoops, deployment status)
    - [ ] **Alertmanager:** Central alerting engine for cluster alerts
    - [ ] **Grafana:** Pre-configured dashboards for K3s health, node load, and Traefik traffic

---

## 🛡️ Phase 7: Day-2 Operations & Data Security

*Goal: Secure and automate the system before migrating live production data.*

- [x] ADR-0006: Dual-Track Update & Lifecycle Strategy adopted (OS security updates vs. playbook K3s upgrades)
- [ ] **SnapRAID Automation:** Script (`snapraid-runner`) with `sync`/`scrub` configured as systemd timer
- [ ] **K3s State Backup:** Daily backup of SQLite/etcd database (`/var/lib/rancher/k3s/server/db` + token) to external storage
- [ ] **Appdata Backup:** Restic/Borg backup for `/mnt/appdata` (PVs) with application-consistent hooks and systemd timer
- [ ] **Hardware, Storage & Backup Monitoring:**
  - [ ] **S.M.A.R.T. Monitoring:** `prometheus-smartctl-exporter` for drive health (pending sectors, NVMe wear level)
  - [ ] **Job & Timer Monitoring:** Monitor SnapRAID and Restic backup jobs (systemd-exporter or Healthchecks ping)
  - [ ] **Node Heartbeat (Dead Man's Switch):** Host-level systemd timer pings an external service (e.g. Healthchecks.io) only while `k3s` is active; a missing ping alerts on both node outage and K3s not starting (e.g. appdata mount or fsck failure). Push model needs outbound traffic only; the receiver must sit outside the homelab failure domain, since in-cluster Alertmanager cannot report its own cluster being down
  - [ ] **Alertmanager Routing:** Connect notification channels (Discord, Telegram, or email) for parity or disk issues

---

## 🚧 Phase 7.5: Pre-Migration Gate & Resilience Verification

*Goal: Prove system resilience and recovery procedures before migrating Unraid data.*

- [ ] **3-2-1 Backup for Irreplaceable Data:** External backup of photos, documents, appdata, and Unraid flash drive
- [ ] Run SMART extended self-tests on all disks & generate media inventory file (`find ... > media-inventory.txt`)
- [ ] **App-by-App Migration Plan:** Migrate services sequentially instead of big-bang transition
- [ ] **Backup Restore Test:** Restore a test application including persistent volume data from backup
- [ ] **Storage Failure Test:** Simulate practical SnapRAID data recovery on test data
- [ ] **Migration Rehearsal:** Fully migrate a single, non-critical application from Unraid to K3s
- [ ] **Rollback Test:** Simulate migration failure → restart previous Unraid service successfully

---

## 🏁 Phase 8: Storage Array Cutover & Data Migration

*Goal: Retain multi-terabyte bulk data disks in-place, migrate application states, and establish SnapRAID parity.*

- [ ] **Phase 8.1: In-Place Drive Attachment & Initial Read-Only Mount:**
  - [ ] Physically attach existing Unraid XFS/Btrfs data drives to the bare-metal host
  - [ ] Mount data disks strictly read-only initially (`ro,norecovery`) via persistent `/dev/disk/by-id/` symlinks
  - [ ] Configure `mergerfs` pool over read-only data mounts for pooled read access
  - [ ] Preserve Unraid parity drive completely untouched (ensuring zero-risk rollback window)
- [ ] **Phase 8.2: Application State Migration & Workload Launch:**
  - [ ] Stop legacy Unraid containers to ensure consistent database states
  - [ ] Rsync application states (`appdata`) from Unraid NVMe to new Tier-2 K3s NVMe storage (PVCs)
  - [ ] Verify file permissions and ownership (UID/GID) on target PVC storage
  - [ ] Launch production workloads via ArgoCD (e.g. Nextcloud, Jellyfin with Intel QuickSync)
  - [ ] Validate application performance and data read access against the read-only mergerfs pool
- [ ] **Phase 8.3: Parity Cutover & Finalization:**
  - [ ] Remount data disks read-write in `/etc/fstab`
  - [ ] Format former Unraid parity disk and configure as dedicated SnapRAID parity drive
  - [ ] Compute initial SnapRAID parity (`snapraid sync`) – concluding the parity rollback window
  - [ ] Enable automated nightly `snapraid-runner` timer
  - [ ] Update router port forwardings (80/443) to Caddy VM (`10.55.192.10` per ADR-0003)
  - [ ] Decommission legacy Unraid boot USB – migration successfully completed!
  - [ ] *Optional:* Deploy homelab dashboard (Homepage)
