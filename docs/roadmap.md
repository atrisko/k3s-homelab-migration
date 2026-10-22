# 📋 Project Roadmap & Task List: K3s Homelab Migration

> **Status:** Phase 3 (K3s Bootstrap & Runtime) · State: October 2026  
> **References:** [README.md](../README.md) · [docs/adr/](adr/) · [docs/reviews/](reviews/)

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

- [x] Establish directory structure (`ansible.cfg`, `inventory/`, `roles/`, `site.yaml`)
- [x] Configure inventory for AWS EC2 referencing Terraform `ssh_config` (`inventory/hosts.yaml`)
- [x] Test connectivity via `ansible all -m ping`
- [x] **Role `os_base`:** Base packages, system hardening & maintenance
  - [x] Base packages (`curl`, `git`, `htop`, `jq`, `open-iscsi`, `nfs-common`, `systemd-timesyncd`)
  - [x] OpenSSH hardening (`sshd_config.d/00-hardening.conf`: key-only authentication, `AllowUsers`, DoS limits)
  - [x] Kernel sysctl hardening (`99-kubernetes-hardening.conf`: loose-mode `rp_filter = 2` per ADR-0005, anti-spoofing, forwarding)
  - [x] Kernel module blacklisting (`99-hardening-blacklist.conf`: obsolete filesystems & uncommon network protocols)
  - [x] Systemd-journald limits (`00-limits.conf`: 1 GB `SystemMaxUse` against K8s DiskPressure)
  - [x] NTP time synchronization via `systemd-timesyncd`
  - [x] Automated security updates via `unattended-upgrades` (ADR-0004)
  - [x] Ansible authentication: `/etc/sudoers.d/10-ansible` with `{{ ansible_user }} ALL=(ALL) NOPASSWD: ALL` (uninterrupted automation without plaintext passwords)
- [x] **Role `os_base` (IPv6 ULA):**
  - [x] Reboot persistence via dynamic detection of `ifupdown` (`/etc/network/interfaces.d/60-ula.cfg`) and `netplan` (`/etc/netplan/60-ula.yaml`) per ADR-0001
  - [x] Immediate non-destructive runtime activation via `ip -6 addr replace`
- [x] **Role `storage_poc`:**
  - [x] Format EBS volume & mount to `/mnt/appdata`
  - [x] Persistent device identification via `/dev/disk/by-id/` (device name independence)
  - [x] Mount option `nofail` configured (prevents boot hangs on detached disks)
  - [x] Storage safety assertion: pre-flight assertion verifying that target storage device variable is defined
- [x] **Ansible Role Modularization & Defaults:**
  - [x] Create `requirements.yaml` for external collections (`ansible.posix`, `community.general`)
  - [x] Define role variables in `defaults/main.yaml` overridable via inventory `group_vars/`

---

## 🚢 Phase 3: K3s & Core Platform Bootstrap (Current Phase)
*Goal: Install container orchestration runtime and bootstrap initial services.*

- [x] Pre-flight assertions: validate IPv6 ULA assignment and active `/mnt/appdata` mountpoint
- [x] K3s dual-stack configuration: generate declarative `/etc/rancher/k3s/config.yaml` before service start (cluster-CIDR, service-CIDR, node-IP per ADR-0001)
- [x] Redirect K3s local-path provisioner to dedicated SSD storage (`default-local-storage-path: "/mnt/appdata"`)
- [x] Install K3s via `/tmp/k3s-install.sh`
- [x] Enable and start K3s systemd service
- [x] Bootstrap ArgoCD via K3s `HelmChart` CRD (`kube-system/argocd`) with pinned chart version (7.7.16)
- [x] Create decoupled root application (`k8s/bootstrap/root-app.yaml`) and apply via task
- [x] Connect ArgoCD to GitHub repository and assign sync permissions (`root-app` syncs from public repository)
- [x] Deploy smoke-test workload (Caddy in `k8s/test-workload/caddy.yaml`) declaratively via GitOps
- [x] **K3s Versioning & Restart Handler:**
  - [x] Pin K3s version (`INSTALL_K3S_VERSION: "{{ k3s_version }}"` in `defaults/main.yaml`)
  - [x] Idempotent upgrade check (evaluate `k3s --version`, execute script only when version differs)
  - [x] Connect `Restart k3s` handler on `config.yaml` modifications
- [x] **Remote `kubectl` & TLS-SAN Configuration:**
  - [x] Declare `k3s_tls_san` in `defaults/main.yaml` and integrate dynamic `tls-san` block in `config.yaml`
  - [x] ADR-0007: Declarative TLS Subject Alternative Names (SANs) for remote K8s API access
  - [x] Refine access model: API port 6443 restricted to `admin_cidr`; remote access primarily via SSH port forwarding (`ssh -L 6443:localhost:6443`)
- [x] **Runtime Storage Guard (Review 2 R2-1):**
  - [x] Add systemd drop-in with `RequiresMountsFor={{ storage_mount_point }}` to `k3s.service`
  - [x] Apply `chattr +i` to the underlying mount directory before mounting (fails write attempts if storage is detached, preventing silent root disk pollution)
- [x] **ArgoCD Modernization (Review 2 R2-2):**
  - [x] Upgrade ArgoCD `HelmChart` CR to a supported 3.x chart line
  - [x] Document version compatibility matrix in ADR-0006
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
- [ ] Provision Debian 13 VM in RemoteLab (`site.yaml`)
- [ ] Validate dual-stack behavior with real router/SLAAC + static ULA in home network
- [ ] Verify 24-hour SLAAC stability under IPv6 forwarding (`accept_ra = 2` verification)
- [ ] **Caddy $\rightarrow$ Traefik Ingress & Header Staging Test (ADR-0003):**
  - [ ] Test Caddy reverse proxy forwarding to Traefik LoadBalancer IP
  - [ ] Verify header propagation (`X-Forwarded-For`, `X-Real-IP`) & Traefik `trustedIPs` on test workload
  - [ ] Validate MetalLB L2-AddressPool in local test subnet
  - [ ] Test passwordless sudo for Ansible user (`/etc/sudoers.d/10-ansible`)
- [ ] Conduct idempotency & reboot audit:
  - [ ] Second playbook run reports `changed=0`
  - [ ] K3s survives host reboot cleanly
  - [ ] Detached storage reboot test: verify K3s service fails safely without polluting root disk

---

## 🖥️ Phase 5: Bare-Metal Foundation (The Hardware Platform)
*Goal: Deploy the validated architecture onto physical hardware – cleanly isolated from production data.*

- [ ] Prepare physical hardware & install base Debian 13 on system SSD
- [ ] **Decoupled 2-Tier Storage Setup for Base System:**
  - [ ] **Tier 1 (OS):** Dedicated SATA SSD for Debian 13 base system (disposable, protects from I/O wear)
  - [ ] **Tier 2 (Appdata & K3s Runtime):** 1 TB M.2 NVMe formatted as single-disk pool (ZFS or Btrfs)
    - [ ] Online mirror preparation: format filesystem allowing non-disruptive online mirror attach (`zpool attach` or `btrfs balance`) once second M.2 is installed
    - [ ] K3s I/O decoupling: configure `data-dir: /mnt/appdata/k3s` (containerd, pod overlays, SQLite WAL) and `default-local-storage-path: /mnt/appdata/storage`
    - [ ] Cache & Ingest partitioning: dedicated volume/dataset with quota for staging ingest prior to array offloading
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
