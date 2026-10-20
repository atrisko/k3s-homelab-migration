# Review 1: k3s-homelab-migration

**Perspective:** Senior DevOps Engineer · **Baseline:** `198e393` (main) · **Scope:** Terraform, Ansible, K8s manifests, documentation, architecture

> [!NOTE]
> I did not modify any files in the repository. A few items (especially the ArgoCD namespace) should be verified directly against the running cluster—the corresponding inspection commands are provided below.

---

## 1. Summary

For a first hands-on journey with Terraform, Ansible, and GitOps, this is **above average**. The underlying mindset is solid: Day-1 and Day-2 concerns are cleanly decoupled, infrastructure is tested disposably first, and there is a thoughtful roadmap with migration gates and rollback strategies—principles where even seasoned engineers often stumble.

The primary areas for improvement lie in **fine-grained implementation details** (idempotency, reboot persistence, version pinning, security baselines) and in **aligning documentation with the current implementation phase**. At times, the documentation describes target architectural goals as already in place.

---

## 2. What is good ✅

| Area | Why it is good |
| :--- | :--- |
| **Day-1 / Day-2 separation** | Ansible manages OS + K3s, ArgoCD handles workloads. Exactly the right model. |
| **Staged testing strategy** | AWS → RemoteLab → Bare Metal, with Phase 7.5 as a pre-migration gate including restore testing. Very mature. |
| **Git hygiene** | Conventional Commits, small atomic commits, clean history. Exemplary. |
| **Terraform basics** | Dedicated VPC instead of default VPC, AMI via data source with owner ID, `.terraform.lock.hcl` committed, state excluded via `.gitignore`. |
| **`local_file` → `ssh_config`** | Clean bridge between Terraform and Ansible, with `IdentitiesOnly` and `0600` permissions. |
| **K3s via `config.yaml`** | Declarative instead of `INSTALL_K3S_EXEC` flags. Right choice. |
| **FQCNs in Ansible** | `ansible.builtin.*`, `community.general.*`: modern and lint-compliant. |
| **No User-Data** | Deliberate choice to leave OS configuration entirely to Ansible. Consistent. |
| **Storage concept** | Decoupled tiers (system SSD / appdata mirror / bulk storage pool) and `default-local-storage-path` moved off the root disk. |
| **Comments** | Code explains the *why*. Valuable for ongoing learning and future maintenance. |

---

## 3. Areas for Improvement (Prioritized)

Legend: 🔴 critical (bug or risk) · 🟠 important · 🟡 nice to have

### 🔴 3.1 IPv6 ULA is not reboot-persistent → K3s fails to start after reboot

[ansible/roles/k3s_install/tasks/main.yaml:16-25](../../ansible/roles/k3s_install/tasks/main.yaml#L16-L25)

`ip -6 addr add` is **ephemeral runtime configuration only**. After a reboot, `fd42::1` disappears. Because `node-ip` explicitly references this address, K3s cannot start cleanly. On bare metal with regular kernel updates, this failure is guaranteed to happen.

Two additional issues exist:
- **Overlapping subnets:** The host receives `fd42::1/64`, and `fd42::/64` resides **inside** `cluster-cidr: fd42::/56`. Host and pod networks must not overlap.
- **Fragile idempotency:** Task change detection relies on parsing `stderr` text. This breaks as soon as iproute2 error messages change across distributions or versions.

**Suggestions:**
- Ask realistically: is dual-stack needed *right now*? AWS does not provide IPv6 routing here, and the home network will likely receive a dynamic GUA prefix from the ISP (a completely different scenario). **Consider deferring IPv6 during the PoC (YAGNI)** and addressing it specifically during RemoteLab or Bare Metal phases.
- If keeping it: configure it persistently (e.g. drop-in in `/etc/network/interfaces.d/` or systemd-networkd, depending on the OS image), select a ULA prefix that does **not** overlap with the pod CIDR (e.g. `fd00:10::/64` for hosts, `fd42::/56` for pods), and verify idempotency via `ansible_facts['all_ipv6_addresses']`.

---

### 🔴 3.2 ArgoCD bootstrap via auto-deploy directory: namespace issue and missing version pinning

[ansible/roles/k3s_install/tasks/main.yaml:54-72](../../ansible/roles/k3s_install/tasks/main.yaml#L54-L72)

1. **Namespace:** The official `install.yaml` from ArgoCD does **not** specify `metadata.namespace` on namespaced resources; it assumes `kubectl apply -n argocd`. However, its ClusterRoleBindings explicitly point to ServiceAccounts in `argocd`. The K3s auto-deploy controller does not automatically deploy non-namespaced manifests into `argocd`. Pods may land in the wrong namespace, causing RBAC resolution to fail.
   **Verify:** `sudo k3s kubectl get deploy -A | grep argocd`. If `kube-system` appears instead of `argocd`, this is the cause.
2. **`stable` is a rolling branch.** It lacks reproducible version pinning. Furthermore, because `get_url` without `force`/`checksum` skips re-downloading an existing file, each machine reflects whatever state existed on the day of its initial install. Two nodes mean two potentially different ArgoCD versions.
3. The root `Application` is also placed into the auto-deploy directory. This creates a dual-reconciler conflict: both K3s and ArgoCD (via `selfHeal`) manage the same object.

**Suggestion:** Use the built-in K3s **Helm controller** with a pinned chart version. This cleanly solves namespace creation, version pinning, and update paths:

```yaml
# /var/lib/rancher/k3s/server/manifests/argocd.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: argocd
  namespace: kube-system
spec:
  repo: https://argoproj.github.io/argo-helm
  chart: argo-cd
  version: "<pinned-chart-version>"
  targetNamespace: argocd
  createNamespace: true
```

Afterwards, bootstrap **only a single root Application** (App-of-Apps pattern). Everything else, *including ArgoCD itself*, is managed by ArgoCD from Git.

---

### 🔴 3.3 Storage: hardcoded `/dev/nvme1n1` and mount without `nofail`

[ansible/roles/storage_poc/tasks/main.yaml](../../ansible/roles/storage_poc/tasks/main.yaml)

- On AWS Nitro instances, **NVMe device enumeration order is non-deterministic**. Formatting a guessed device name is a classic risk for data corruption, especially on bare metal with 6+ drives.
- **Without `nofail`**, missing storage forces the system into systemd emergency mode at boot. On AWS, this leaves the instance unreachable over SSH.
- If the mount fails or is missing, local-path **silently writes to the root disk** under `/mnt/appdata`. This often goes unnoticed until the root disk fills up completely.

**Suggestion:**
```yaml
src: "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_{{ ebs_volume_id | replace('-', '') }}"
# or even better: mount by UUID (via blkid / ansible_facts)
opts: defaults,nofail
```
Expose the volume ID via Terraform outputs. On bare metal, always reference disks using `/dev/disk/by-id/…` or `UUID=`, never raw `/dev/sdX` names.

---

### 🔴 3.4 Self-hosted runner + public repo = security risk (Planning, Phase 4/5)

The README mentions running a self-hosted GitHub Actions runner in your local LAN with SSH access to the production host. The repository is public. **GitHub explicitly advises against using self-hosted runners on public repositories**, because pull requests from forks can execute arbitrary code on the runner. An attacker could pivot directly into the home network with SSH access to the server.

**Suggestion:** Either keep the repository private, or (often simpler for a single-node homelab) **trigger Ansible locally or manually**, restricting CI to linting and check-mode on GitHub-hosted runners. If automated deployment is required: enforce GitHub Environments with required reviewers and prohibit workflow runs on fork PRs.

---

### 🟠 3.5 K3s installation: unversioned, missing restart handler

[ansible/roles/k3s_install/tasks/main.yaml:2-6, 74-84](../../ansible/roles/k3s_install/tasks/main.yaml#L74-L84)

- Without `INSTALL_K3S_VERSION`, the script installs *whatever version is current upstream today*. The AWS PoC and bare-metal environments could end up running disparate Kubernetes minor versions, invalidating PoC test results.
- `creates: /usr/local/bin/k3s` prevents any in-place upgrades.
- Modifying `config.yaml` **does not trigger a K3s restart**. Changes do not take effect, yet Ansible reports "ok".

**Suggestion:**
```yaml
# roles/k3s_install/defaults/main.yaml
k3s_version: "v1.xx.y+k3s1"

# tasks
- name: Write K3s config
  ansible.builtin.template:
    src: config.yaml.j2
    dest: /etc/rancher/k3s/config.yaml
  notify: Restart k3s

- name: Install K3s
  ansible.builtin.command: /tmp/k3s-install.sh
  environment:
    INSTALL_K3S_VERSION: "{{ k3s_version }}"
  when: installed_k3s_version != k3s_version   # Query installed version via `k3s --version` first
```
For inspiration on robust patterns, refer to the official [k3s-io/k3s-ansible](https://github.com/k3s-io/k3s-ansible) repository.

---

### 🟠 3.6 Remote `kubectl` does not work: missing TLS SAN

Port `6443` is permitted in the security group, but `node-ip` references only the *private* IP (10.0.1.x). The API server certificate does not include the public IP address. Running `kubectl` remotely from an external workstation results in a TLS validation error, which can tempt engineers into using `insecure-skip-tls-verify`.

**Suggestion:** Include `tls-san: ["<public-ip>"]` in `config.yaml` (injected as an inventory variable). Alternatively, and preferably: keep port 6443 closed externally and access the API via an SSH tunnel (`ssh -L 6443:localhost:6443 aws-k3s-poc`).

---

### 🟠 3.7 Terraform: security defaults and replacement risks

[network.tf](../../terraform/aws-poc/network.tf) · [main.tf](../../terraform/aws-poc/main.tf)

| Issue | Suggestion |
| :--- | :--- |
| SSH **and K8s API** open to `0.0.0.0/0`. An exposed API is scanned within minutes. | Restrict via `admin_cidr` variable to your own IP (e.g. via `data "http"` querying `checkip.amazonaws.com`). |
| `most_recent = true` on AMI: Whenever Debian publishes a new image, the next `apply` **replaces** the running instance. | Add `lifecycle { ignore_changes = [ami] }` or pin the specific AMI ID. |
| IMDSv1 permitted | Require IMDSv2 via `metadata_options { http_tokens = "required" }`. |
| EBS / root volume unencrypted | Enable `encrypted = true`. |
| Missing `required_version` | Enforce `required_version = ">= 1.5.0"`. |
| Hardcoded region, profile, instance type | Extract into variables and add `default_tags` on the provider (`Project`, `ManagedBy = "terraform"`) for cost tracking. |
| No budget safety guard | Add `aws_budgets_budget` with an email notification threshold. |
| `graph.svg` tracked despite `.gitignore` | Was committed prior to adding ignore rule: clean up via `git rm --cached terraform/aws-poc/graph.svg`. |

For an ephemeral single-user PoC, `StrictHostKeyChecking no` / `host_key_checking = False` is **acceptable**. Bear in mind that it offers no protection against MITM attacks, and should **not** be carried over to bare-metal production.

---

### 🟠 3.8 Ansible: hardcoded values and undeclared dependencies

- **Configuration values are hardcoded** (device names, filesystem paths, CIDRs, software versions). The documentation promises environment parity by "simply switching the inventory." This requires defining baseline defaults in `roles/*/defaults/main.yaml` and overriding them per environment in `inventory/<env>/group_vars/`.
- **`requirements.yml` is missing.** Roles depend on `community.general` and `ansible.posix`. On a clean CI runner (Phase 4), playbook execution will fail.
  ```yaml
  collections:
    - name: community.general
    - name: ansible.posix
  ```
- **`os_base` executes `dist-upgrade` on every run** without coordinating reboots. On production, running this automatically on every push introduces operational risk: kernel upgrades without reboot or unexpected mid-day package updates. Decouple "establishing baseline configuration" (idempotent, safe at any time) from "patch management" (dedicated playbooks or `unattended-upgrades`).
- **"OS Hardening"** is outlined in docs and roadmap, but lacks concrete implementation (SSH hardening, firewall rules, unattended upgrades).
- Linting details flagged by `ansible-lint`: standardize `yes` → `true`; prefer templates (`.j2` in `templates/`) over inline `content:` for multi-line configuration files.

---

### 🟠 3.9 GitOps structure and secrets management

- **Secrets management is absent from initial planning**, which becomes an immediate blocker during Phase 8 (Nextcloud DB, API credentials, etc.). In a public Git repository, secrets cannot be stored in plaintext. Recommended solutions:
  - **SOPS + age** (lightweight, easily integrated with ArgoCD),
  - **Sealed Secrets**,
  - **External Secrets Operator + 1Password** (integrates naturally with existing 1Password workflows).
- **Establish repository structure for ArgoCD early**, for example:
  ```text
  k8s/
  ├── bootstrap/root-app.yaml   # Sole Application provisioned by Ansible
  ├── infra/                    # argocd, cert-manager, traefik-config, …
  └── apps/<app>/               # jellyfin, nextcloud, …
  ```
- Application workloads should not reside in the `default` namespace. Use dedicated namespaces with `syncOptions: [CreateNamespace=true]`.
- [caddy.yaml](../../k8s/test-workload/caddy.yaml): Acceptable for smoke tests, but establish production habits: pinned image tags (avoid rolling tags like `2-alpine`; track with Renovate), `resources.requests/limits`, readiness/liveness probes, and explicit `securityContext`.

---

### 🟠 3.10 Documentation Alignment (Doc Drift)

The documentation is comprehensive and visually well-structured, but in several places it reflects future target states rather than the current implementation phase:

| Documentation states | Reality |
| :--- | :--- |
| Manifests in `kubernetes/**` | Directory is named `k8s/` |
| `inventory/remotelab.yaml`, groups `aws_poc` / `bare_metal` | Does not exist; only `k3s_cluster` present |
| EC2 `t3.micro` / `t3.large` | Code uses `t3.medium` (`t3.micro` with 1 GB is insufficient for K3s + ArgoCD) |
| ArgoCD = Phase 6, "planned" | Already implemented in Phase 3 |
| "OS Hardening", CI pipeline with `webfactory/ssh-agent` | Not yet implemented |
| "guarantee zero downtime" | In-place HDD migration realistically entails planned minimal downtime |
| "Air-Gapped Credential Boundary" | An internet-connected runner is not air-gapped |
| "0700 is the required secure permission" | Recommended best practice, rather than strictly required |

Additionally, there are minor language inconsistencies (German/English mix in comments and diagrams).

**Suggestions:**
- **README = Active State + Roadmap.** Clearly designate planned milestones as *planned*.
- Tone down overly absolute phrasing ("strictly", "zero-touch", "guarantee") to keep the technical tone grounded and credible for external review.
- **Adopt Architecture Decision Records (ADRs)** (`docs/adr/0001-....md`, following: context → decision → consequences). For engineers, this is an invaluable documentation format because it captures the rationale behind key technical choices.

---

### 🟡 3.11 Additional Notes

- **Pre-commit hooks:** Configure `terraform fmt`, `tflint`, `yamllint`, `ansible-lint`, and `gitleaks`. A 30-minute setup eliminates 80% of minor syntax and formatting catches early.
- **Generate inventory dynamically from Terraform** instead of relying on a relative path `-F ../terraform/aws-poc/ssh_config`, which only works when invoked from within `ansible/`.
- **Terraform remote state** (S3 with state locking) is not strictly required for an ephemeral single-user PoC; local state is fine until CI automation takes over.
- **`open-iscsi`** is only required for distributed storage engines like Longhorn; for local-path storage it is unnecessary.
- AWS provider `~> 5.0`: Evaluate major version upgrades intentionally.

---

## 4. Architectural Considerations (Strategic)

1. **Assessing the value of the AWS PoC stage:** It effectively validates Terraform skills, but many runtime behaviors differ from bare metal: NVMe naming, lack of IPv6 routing, cloud virtual networking, and absence of mergerfs/SnapRAID. Local virtual machines (Multipass, Vagrant, or Hyper-V RemoteLab) provide higher fidelity for bare-metal pre-validation. **Recommendation:** Retain AWS as a Terraform learning sandbox, but execute operational sign-offs in RemoteLab.
2. **Unraid → SnapRAID: the parity consideration.** Existing XFS/Btrfs data disks from Unraid can be mounted individually in Debian, enabling in-place data retention. However, **Unraid parity is incompatible with SnapRAID.** The parity drive must be reformatted and parity recalculated from scratch. During this recalculation window, data remains unprotected by parity. A full 7–8 TB backup is not strictly required if following a tiered risk strategy:
   - **Irreplaceable data** (appdata, family photos, critical documents, Unraid flash backup) secured under a 3-2-1 backup scheme with offsite copies and verified restore procedures.
   - **Replaceable media** deliberately classified as accepted risk and documented accordingly.
   - **Minimize exposure window:** Mount data disks read-only initially (XFS: `ro,norecovery`). Do not overwrite the Unraid parity disk until the new environment is fully validated, preserving the ability to roll back cleanly to Unraid.
   - Run pre-migration SMART extended self-tests on all disks and catalog media files (`find … > media-inventory.txt`).
   (Verify whether any Unraid disks use encryption, which would require `cryptsetup`.)
3. **Push-based Ansible deployments on every commit** introduce unnecessary risk for a single-node homelab. Run check-mode in CI, but restrict live production deployment to manual triggers or gated approvals.
4. **K3s backup strategy:** For a single-node SQLite deployment, backing up `/var/lib/rancher/k3s/server/db` and the cluster token is straightforward. More importantly: with complete GitOps declaration, the cluster state itself is largely ephemeral. The critical assets requiring backup are **Persistent Volume (PV) data** (handled via restic in Phase 7).
5. **Managing operational complexity:** Evaluating three environments, automated CI/CD, self-hosted runners, ArgoCD, dual-stack networking, and SnapRAID on a single host. As an educational project, this breadth is excellent. Operationally, continuously ask: *"Does this component provide concrete value to justify its ongoing maintenance burden?"*

---

## 5. Conclusion

**Rating (for a first IaC project): solid 2 / "good, with clear potential".**

The foundational architectural decisions are sound, and the structured workflow (roadmap phases, verification gates, clean commit hygiene, disposable testing first) demonstrates sound engineering discipline. The main areas for growth involve operational edge cases: ensuring configurations survive reboots, pinning versions, parameterizing variables, and keeping documentation aligned with the active codebase.

Key takeaway: **"Works once" differs from "idempotent, reproducible, and reboot-safe."** Make it standard practice after every feature to execute `terraform destroy && terraform apply`, run the playbook **twice** consecutively (second run expecting `changed=0`), and perform a full host **reboot**. This workflow naturally uncovers issues like 3.1, 3.3, and 3.5 early.

### Top 5 Next Steps

1. 🔴 Remove IPv6 from the PoC (or implement it persistently without CIDR overlap) and establish reboot verification.
2. 🔴 Bootstrap ArgoCD via `HelmChart` CR with a pinned version, establish a single root Application (App-of-Apps), and verify the ArgoCD namespace on the cluster.
3. 🔴 Mount storage via `/dev/disk/by-id/` or UUID with `nofail`. Re-evaluate self-hosted runner strategy for the public repository.
4. 🟠 Parameterize role variables in `defaults/` and `group_vars/`, commit `requirements.yml`, and pin the K3s version with a dedicated restart handler.
5. 🟠 Align documentation with the current implementation state, refine phrasing, and introduce ADRs. Finalize the secrets management strategy prior to Phase 6.

> [!TIP]
> When executing these items incrementally, `/plan` provides an effective way to break them down into verifiable implementation tasks.
