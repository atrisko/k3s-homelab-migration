# Review 2: k3s-homelab-migration

**Perspective:** Senior DevOps / Platform Engineer · **Baseline:** `8a32569` (main, 2026-10-20) · **Previous review:** [review-1.md](review-1.md) (baseline `198e393`)
**Scope:** Terraform, Ansible, K8s manifests, README/docs, ADRs 0001–0007, [roadmap](../roadmap.md)

> [!NOTE]
> Per the agreement, findings 3.4, 3.9 and 3.11 from review 1 were **not** worked on. I only record their current status. I do not repeat them as new findings.
> ADRs were adopted at Phase 3. I don't count it as a defect that earlier decisions have no ADR, but I do point out the ones that still have consequences ahead.

---

## 1. Summary

There is clear progress. Every 🔴 item from review 1 that was in scope has been addressed, and most of the fixes are good: a persistent and non-overlapping ULA, a HelmChart CR with a pinned version, `by-id` + `nofail`, a pinned K3s version with an upgrade path and a restart handler, and a Terraform security baseline. The commit history is still exemplary.

Three topics remain:

1. **Several fixes only work at playbook time, not at boot time.** The best example is the storage guard. Review 1 ended with *"has it survived a reboot?"*, and that question is still open. The roadmap's reboot audit (Phase 4.5) has not been done yet, but the README already claims the result.
2. **Documentation alignment still requires refinement on operational details.** While major gaps from Review 1 were resolved, some detail-level discrepancies remain: operational controls described ahead of implementation (e.g. systemd mount guards), ADR cross-references to clean up, and aligning planned roadmap items with the current codebase.
3. **The roadmap contains decisions that are hard to reverse and must be made *before* the first bare-metal boot**: K3s `data-dir`, `disable: servicelb`, the Tier-2 filesystem, and the order of the in-place HDD migration. Some of these contradict each other (see §6).

**Verdict:** a solid step from "good, with clear potential" towards "good". The code is now mostly reproducible. The next lever is **runtime resilience** and **planning consistency**, not new features.

---

## 2. Status of review 1 findings

| # | Topic | Status | Remarks |
| :--- | :--- | :--- | :--- |
| 3.1 | IPv6 ULA not reboot-safe | ✅ Fixed | Persistent, outside the pod CIDR, idempotent via facts. Remaining caveats: RA/forwarding interaction and framework detection (→ R2-4, R2-5). |
| 3.2 | ArgoCD bootstrap | ✅ Fixed | HelmChart CR, pinned version, root app outside the auto-deploy directory. **But** the pinned version is badly outdated (→ R2-2), and the "App-of-Apps" is not one yet (→ R2-9). |
| 3.3 | Storage device / `nofail` | 🟡 Partially | `by-id` and `nofail` are done. The "silent root-disk writes" risk is only guarded at playbook time, not at boot (→ R2-1). The claimed "root-disk formatting guard" does not exist (→ §4). |
| 3.4 | Self-hosted runner + public repo | ⏸ Not in scope | The README now states that runners get no LAN/SSH access. The roadmap still has an open item about SSH secrets for AWS (→ §6, Phase 4). |
| 3.5 | K3s versioning / handler | ✅ Fixed | Small robustness gaps remain (→ R2-6). |
| 3.6 | TLS SAN | ✅ Fixed (mechanism) | `k3s_tls_san` is never set in any inventory, and port 6443 is still open even though SSH tunnelling is the preferred access path (→ R2-14). |
| 3.7 | Terraform security defaults | ✅ Mostly | Budget alarm is still open, but ADR-0006 treats it as an existing control (→ §5). `graph.svg` is no longer tracked. |
| 3.8 | Ansible variables / deps / patching / hardening | 🟡 Mostly | `requirements.yaml`, `defaults/`, `dist-upgrade` removal and hardening are done. Not done: `yes` → `true`, inline `content:` → templates, a host firewall concept (→ R2-12, §5). |
| 3.9 | GitOps structure / secrets | ⏸ Not in scope | Still open. Note: `caddy:2-alpine` now also contradicts **ADR-0006** (strict tag pinning). |
| 3.10 | Doc drift | 🟡 Partially | The original drift table is resolved. Remaining detail discrepancies are noted in §4. Recommend softening absolute terms ("zero-touch", "enterprise-grade", "guarantee", "strictly") for a more grounded engineering tone. |
| 3.11 | Misc | ⏸ Not in scope | Partially resolved as a side effect: Terraform now generates the inventory. The relative `-F ../terraform/aws-poc/ssh_config` path survived inside the generated inventory. `open-iscsi` and AWS provider `~> 5.0` are unchanged. |

---

## 3. New findings: code

Legend: 🔴 critical (bug or risk) · 🟠 important · 🟡 nice to have

### 🔴 R2-1 Storage guard only at playbook time: K3s can start on the root disk after a reboot

[ansible/roles/k3s_install/tasks/main.yaml:28-32](../../ansible/roles/k3s_install/tasks/main.yaml#L28-L32) · [ansible/roles/storage_poc/defaults/main.yaml:4](../../ansible/roles/storage_poc/defaults/main.yaml#L4)

The `assert` protects the *Ansible run*. At boot, `nofail` does what it should: the system comes up without the disk. But `k3s.service` has no dependency on `/mnt/appdata`, so K3s starts anyway, and local-path writes new PVs into the empty directory on the root filesystem. When the disk shows up again later, the mount hides that data, and the pods see their old data again. Two diverging datasets, and nobody notices.

With the planned `data-dir: /mnt/appdata/k3s` (roadmap Phase 5), the same case becomes **a fresh, empty cluster** on the root disk. Stopping K3s from starting would be the better failure mode.

**Suggestion:** add a systemd drop-in for `k3s.service` with `RequiresMountsFor={{ k3s_storage_path }}` (or `BindsTo=`/`After=` on the `.mount` unit), plus `chattr +i` on the empty mountpoint as a cheap extra guard. Keep `nofail` for the host. Make the *service* fail, not the *boot*.

---

### 🔴 R2-2 Argo CD 2.13 (chart 7.7.16) is EOL and far behind K3s v1.37

[ansible/roles/k3s_install/defaults/main.yaml:2-7](../../ansible/roles/k3s_install/defaults/main.yaml#L2-L7)

Chart `7.7.16` ships Argo CD **v2.13**, which dates from early 2025. Argo CD supports only the three most recent minor releases, so 2.13 has been out of support for a long time. It is also far outside the Kubernetes versions it was tested against. K3s `v1.37.1` is several minors newer.

Argo CD **3.x** brought breaking changes, for example the default resource-tracking method and RBAC behaviour. **Now** is the cheapest moment to do that migration: the cluster is disposable and has no real applications.

**Suggestion:** move to a current 3.x chart, write down the compatibility check (Argo CD ↔ Kubernetes matrix) as part of the upgrade procedure in ADR-0006, and let Renovate track it from Phase 4 on. The comment `# Chart version 7.7.x packages Argo CD v2.13.x` is helpful. Keep a comment like that for every version bump.

---

### 🟠 R2-3 `node-ip` is derived from a regex instead of the variable, and roles share hidden coupling

[ansible/roles/k3s_install/defaults/main.yaml:13-21](../../ansible/roles/k3s_install/defaults/main.yaml#L13-L21) · [ansible/roles/k3s_install/tasks/main.yaml:48](../../ansible/roles/k3s_install/tasks/main.yaml#L48) · [ansible/roles/os_base/defaults/main.yaml:28](../../ansible/roles/os_base/defaults/main.yaml#L28)

- `k3s_install` reads `os_ipv6_ula` and `storage_mount_point` from *other roles' defaults* and keeps its own fallback copies. The ULA `fd85:cc6d:b16f:30::10/64` is now written down in **two** places. This works only because Ansible exposes role defaults to roles that run later in the same play. If `k3s_install` runs on its own (`--tags k3s_install` still works, but a separate play would not), the values silently fall back to the copies.
- `node-ip` comes from matching all host IPv6 addresses against the regex `^fd85:cc6d:b16f:30::`. That is indirect: you already *know* the address, it is the variable. The regex also depends on `::` appearing in the configured value.
- The IPv4 part comes from `default_ipv4.address`. In RemoteLab that is a DHCP address (`10.100.34.71`). If the lease changes, K3s keeps running with a stale `node-ip` until the next playbook run, and then restarts.

**Suggestion:** move cross-cutting values (`node_ipv6_ula`, `node_ipv4`, `appdata_path`) into `inventory/group_vars/all.yaml` or `host_vars/`. Set `node-ip` directly from them (`ansible.utils.ipaddr('address')`). Keep the facts check only as an `assert`. For RemoteLab, use a DHCP reservation or a static address.

---

### 🟠 R2-4 IPv6 forwarding disables SLAAC unless `accept_ra=2`, and runtime state ≠ boot state

[ansible/roles/os_base/files/99-kubernetes-hardening.conf:16](../../ansible/roles/os_base/files/99-kubernetes-hardening.conf#L16) · [ansible/roles/os_base/tasks/main.yaml:83-117](../../ansible/roles/os_base/tasks/main.yaml#L83-L117)

With `net.ipv6.conf.all.forwarding = 1`, the kernel ignores Router Advertisements on interfaces where `accept_ra=1`, which is the default. ADR-0001 depends on the node getting its **GUA via SLAAC** for internet access.

- The ifupdown stanza sets `accept_ra 2`. That is correct, but it only takes effect when the interface is brought up again. After the first playbook run, sysctl is reloaded at runtime while the interface still has `accept_ra=1`. The GUA and the IPv6 default route then expire once their lifetime runs out. After a reboot everything looks fine. That is the kind of "works after reboot, breaks after a few hours" bug that is hard to trace.
- The netplan variant does not set `accept-ra` at all. On AWS that doesn't matter (no IPv6), but it is the code path a cloud-image-based host would use.

**Suggestion:** set `net.ipv6.conf.<iface>.accept_ra = 2` explicitly (sysctl or netplan `accept-ra: true` together with a forwarding-aware setting), and add *"GUA + IPv6 default route still present 24 h after the playbook run"* to the RemoteLab dual-stack test (Phase 4.5).

---

### 🟠 R2-5 Network framework detection by "directory exists"

[ansible/roles/os_base/tasks/main.yaml:73-111](../../ansible/roles/os_base/tasks/main.yaml#L73-L111)

`/etc/network/interfaces.d` and `/etc/netplan` can both exist. Leftover directories, cloud images with `ifupdown` still installed, and Debian images that ship netplan alongside it all happen in practice. In that case **both** files are written, and whether the one that matters is actually read is left to chance.

**Suggestion:** decide based on the *active* service (`ansible_facts.services['networking.service']`, `systemd-networkd`, presence of `netplan` binary + generated config), make the two branches mutually exclusive (`when: … else …`), and fail loudly if neither applies.

---

### 🟠 R2-6 K3s install: unpinned script, `/tmp`, substring version check

[ansible/roles/k3s_install/tasks/main.yaml:2-6, 91-102](../../ansible/roles/k3s_install/tasks/main.yaml#L91-L102)

- `https://get.k3s.io` is a moving target and is downloaded without a checksum. Every upstream change, and every reboot (because `/tmp` gets cleaned), shows up as `changed`. So `changed=0` is not reachable after a reboot. The script also runs as root without verification.
- `k3s_version not in k3s_check.stdout` is a substring test: `v1.37.1+k3s1` is "contained" in `v1.37.1+k3s10`. That's an edge case, but it is a pattern worth unlearning.
- Changing `cluster-cidr`/`service-cidr` after the first start is not supported (your own ADR-0001). Ansible still writes the new values without complaint and restarts K3s.

**Suggestion:** download the script from the version tag (`https://raw.githubusercontent.com/k3s-io/k3s/{{ k3s_version }}/install.sh`) to a persistent path (`/usr/local/lib/k3s-install.sh`), with a `checksum:`. Parse the version with a regex (`regex_search('v\\S+')`) and compare for equality. For immutable keys, add an `assert` that compares them against the running cluster, or at least a clear comment in `defaults/`.

---

### 🟠 R2-7 `host_key_checking = False` globally, now also for RemoteLab

[ansible/ansible.cfg:4](../../ansible/ansible.cfg#L4)

Review 1 accepted this *for the ephemeral AWS PoC* and asked you not to carry it over to bare metal. Because it sits in `ansible.cfg`, it already applies to RemoteLab, and it will apply to `production.yaml` as soon as that file exists. For AWS it is not even needed, because the generated `ssh_config` already sets `StrictHostKeyChecking no`.

**Suggestion:** remove it from `ansible.cfg`. For AWS, rely on the generated `ssh_config` that already handles this. For RemoteLab and bare metal, use `known_hosts` (or `StrictHostKeyChecking accept-new`).

---

### 🟠 R2-8 Kernel excluded from security updates, but automatic reboots are on

[ansible/roles/os_base/tasks/main.yaml:18-49](../../ansible/roles/os_base/tasks/main.yaml#L18-L49) · [ADR-0004](../adr/0004-separation-day-1-provisioning-and-os-patch-management.md)

Today's setup gets the trade-off backwards. Kernel CVEs are the most relevant class of bug for container escapes, and they are exactly the ones that are **not** patched automatically. At the same time you accept a reboot at 03:00 anyway. ADR-0004's argument about "driver integrity (open-iscsi, nfs)" does not hold: both are in-tree. Out-of-tree modules only become an issue with **ZFS via DKMS**, which the roadmap is considering for Tier 2 (→ §6).

**Suggestion:** either allow kernel updates (with reboot at 03:00, plus `needrestart` or a monitoring hook), or keep the blacklist and make it *visible* that a kernel update is pending (node-exporter textfile / apt collector → alert). Tie the decision to the Tier-2 filesystem choice. Without ZFS/DKMS, the main reason for the blacklist goes away.

---

### 🟠 R2-9 The root app is not an App-of-Apps yet, and its finalizer cascades

[k8s/bootstrap/root-app.yaml:6-12](../../k8s/bootstrap/root-app.yaml#L6-L12)

- `path: k8s/test-workload` points straight at workload manifests, not at a directory of `Application` objects. The README and docs call it "App-of-Apps".
- `resources-finalizer.argocd.argoproj.io` + `prune: true` on the **root** app means that deleting the root app later deletes *every* child app **and** its resources, including PVCs.

**Suggestion:** before Phase 6, point the root app at `k8s/apps/` (Applications or an ApplicationSet). Leave the cascading finalizer off the root app, and annotate stateful resources with `argocd.argoproj.io/sync-options: Prune=false` / `Delete=false`.

---

### 🟠 R2-10 Personal email address in public role defaults (unused)

[ansible/roles/os_base/defaults/main.yaml:16](../../ansible/roles/os_base/defaults/main.yaml#L16)

`os_mail` contains a personal Gmail address in a public repo. Scrapers pick that up. The variable is not even used: the mail lines are commented out, and no MTA is installed, so `apt-listchanges` has no way to deliver anything.

**Suggestion:** use a placeholder in `defaults/` (`os_base_mail: ""`), set the real value in an untracked `host_vars/` or via Vault, and only render the mail lines when it is set. If you decide notifications should go to Alertmanager instead (Phase 7), remove it completely.

---

### 🟡 R2-11 Terraform odds and ends

- [network.tf:58-72](../../terraform/aws-poc/network.tf#L58-L72): 80/443 are open to `0.0.0.0/0`, but nothing is published publicly (Traefik only answers with 404). For a PoC, `admin_cidr` is enough here too.
- [network.tf:35-41](../../terraform/aws-poc/network.tf#L35-L41): the `http` response is not validated. If checkip fails, the result is a broken CIDR. Add a `postcondition { condition = self.status_code == 200 }`.
- [main.tf:105](../../terraform/aws-poc/main.tf#L105): the generated inventory still has `-F ../terraform/aws-poc/ssh_config`. `${abspath(path.module)}/ssh_config` costs nothing here.
- [providers.tf](../../terraform/aws-poc/providers.tf): `hashicorp/local` is used but not listed in `required_providers`. It is only pinned implicitly through the lock file.
- [variables.tf:27](../../terraform/aws-poc/variables.tf#L27): `"e.g. t3.medium, t3.medium"`.

### 🟡 R2-12 Ansible hygiene (this is what `ansible-lint` will report in Phase 4)

- `yes` → `true` ([os_base/tasks/main.yaml:6, 68, 192](../../ansible/roles/os_base/tasks/main.yaml#L6), [k3s_install/tasks/main.yaml:109](../../ansible/roles/k3s_install/tasks/main.yaml#L109)). This was already in review 3.8.
- Handler names in lowercase (`restart ssh`) → `name[casing]`.
- Role variables without the role prefix (`os_*` instead of `os_base_*`, `storage_*` instead of `storage_poc_*`) → `var-naming[no-role-prefix]`.
- Overwriting `50unattended-upgrades` (a dpkg conffile) leads to conffile conflicts on package updates. A drop-in such as `52unattended-upgrades-local` is the clean way. The `debconf` task is redundant once `20auto-upgrades` is written directly.
- `Defaults logfile=/var/log/sudo.log` has no logrotate configuration (sudo already logs to the journal, which is capped).
- Mixed languages in code comments: [k3s_install/defaults/main.yaml:15, 20](../../ansible/roles/k3s_install/defaults/main.yaml#L15) ("nach", "Erkennung für").
- Task name "Create ext4 filesystem on the AWS EBS volume" also runs against the RemoteLab SCSI disk, and the filesystem type is a variable.
- 13 trailing blank lines at the end of [os_base/tasks/main.yaml](../../ansible/roles/os_base/tasks/main.yaml#L218-L230).
- [inventory/remotelab.yaml](../../ansible/inventory/remotelab.yaml): an internal IP and username from a managed corporate network (ADR-0002) are committed to a public repo. Low risk, but avoidable (`hosts.yaml.example` pattern).

---

## 4. Documentation Alignment & Drift

| Location | Docs say | Reality |
| :--- | :--- | :--- |
| [roadmap.md:49](../roadmap.md#L49) | "Mount Guard: pre-flight check preventing accidental root disk formatting" ✅ | [storage_poc](../../ansible/roles/storage_poc/tasks/main.yaml#L2-L9) only checks that `data_disk_device` is defined. Nothing checks that the device is not the root disk. |
| [README.md:41](../../README.md#L41) | "All configuration … is reboot-persistent and verified through repeated playbook execution (`changed=0`)" | The reboot/idempotency audit is still **open** in the roadmap (Phase 4.5). After a reboot, `get_url` → `/tmp` already reports `changed` (R2-6). |
| README L123, ansible.md, roadmap | "App-of-Apps root application" | The root app points straight at the workload (R2-9). |
| [ansible.md:198, 211](../ansible.md#L198) | Dual-reconciler prevention / bootstrap "per ADR-0006" | ADR-0006 is about the update strategy and says nothing about either topic. The bootstrap decision has no ADR (→ §5). |
| [ansible.md:24](../ansible.md#L24) | `k3s_install` = "IPv6 ULA, K3s, Mount Guard & ArgoCD" | The ULA moved to `os_base`. |
| [ansible.md:9](../ansible.md#L9) | "tested on Debian 12/13" | AMI filter and README: Debian 13 only. |
| [ansible.md:51](../ansible.md#L51) | `pipelining`: "Reuses SSH connections" | That is ControlPersist. Pipelining sends modules over stdin instead of copying temp files. |
| [ansible.md:74](../ansible.md#L74) | Kernel "blacklisted from uncoordinated auto-reboots" | Excluded from auto-**upgrade**. Reboots still happen. |
| ansible.md:130, sudoers comment | NOPASSWD "for … CI/CD pipelines" | The README rules out CI access to hosts. |
| [terraform.md:74](../terraform.md#L74) | Inventory contains "the public IP" | The IP is only in `ssh_config`. The inventory references it via `-F`. |
| [terraform.md:16](../terraform.md#L16), README | `t3.small` "Free-Tier eligible" | Depends on the account (new free plan vs. legacy free tier). Better: "low cost". |
| README L36/L53 vs. roadmap L127 | Tier 2 = "SSD/NVMe **mirror**" | Roadmap: a single NVMe, with the mirror *later*. |
| README L55, ADR-0006 L39/L63/L72 | "< 0.05 € per test cycle" / "< $2.00" / "fractions of a euro" / "< 5 € per year" | Four different cost claims. For a 2–4 h cycle (t3.small + public IPv4 + EBS), roughly €0.10–0.20 is realistic. |
| README Quickstart §5 | `ansible-playbook -i inventory/remotelab.yaml site.yaml` | The first run against a fresh Debian install needs `-K` (`--ask-become-pass`), because NOPASSWD is only set up *by* that run. |
| [roadmap.md](../roadmap.md) (public) | "Review 3.7", "Review 4.2", … | `review.md` is gitignored, so public readers can't resolve these references. |
| `TODO.md` vs. `docs/roadmap.md` | — | Identical content (except the header) kept in two places, so drift is guaranteed. Keep one, and make the other a link or delete it. |
| [roadmap.md:162](../roadmap.md#L162) | "Connect ArgoCD to GitHub repository" (open) | Already done (`67f96ca`, root app syncs from the public repo). |
| [review-1.md](review-1.md) | Links to `/Users/alex/...` | Broken on the current Linux workspace. Prefer relative links. |

---

## 5. ADR review

**Overall:** the format is used well (context → decision → consequences → alternatives), the trade-offs are named honestly, and ADR-0005 and ADR-0007 are especially good. Given that ADRs were adopted mid-project, the README note about retroactive ADRs is the right approach.

### Cross-cutting

- **A `Proposed` status is missing.** ADR-0003 and large parts of ADR-0006 describe things that don't exist yet, as present-tense facts (*"Automated AWS Budget Alarms guard against…"*, *"Caddy runs on…"*). Add `Proposed` (or `Accepted – not yet implemented`) to the status list in [adr/README.md](../adr/README.md). That way an ADR doesn't become doc drift by itself.
- **Buzzwords are still there:** "zero-touch" (0007), "enterprise-grade" (0006), "Instant Rollback Guarantee" (0006), "strictly" (0003/0004). The content is good, and the tone takes away from it.
- **Missing ADRs whose consequences are still ahead** (worth writing *now*, not retroactively):
  1. **Argo CD bootstrap model:** HelmChart CR owned by K3s, root app applied once by Ansible, Argo CD *not* self-managed. This is a real decision with alternatives (self-managed Argo, Flux, `kubectl apply` of install.yaml). The docs currently attribute it to ADR-0006 by mistake.
  2. **Tier-2 filesystem and K3s `data-dir`** (ZFS vs. Btrfs vs. ext4/LVM). Hard to reverse, and it affects ADR-0004 (DKMS/kernel) and containerd (overlayfs on ZFS).
  3. **Secrets management.** The roadmap calls it a gate before Phase 6.
  4. **LoadBalancer/ingress** (MetalLB vs. K3s ServiceLB, see §6).
  5. **Host firewall concept.** Deliberately none, relying on OPNsense + K3s iptables? Or nftables on the host? Either answer is fine, but it should be written down.

### Per ADR

| ADR | Remarks |
| :--- | :--- |
| **0001** IP plan | Strong. *Open points* refers to "ADR-0002" for the reverse proxy, but that is **ADR-0003**. The LB pool reserves `fd85:cc6d:b16f:30::200–249`, while the roadmap's MetalLB pool is IPv4-only (→ §6). Add the `accept_ra=2` consequence (R2-4) under trade-offs. |
| **0002** Control node | Fine. Open question: how is the SSH key handled on the control VM? The README talks about the 1Password SSH agent, which most likely isn't available on that VM. |
| **0003** Caddy VM | The reasoning is sound. Missing: (a) **TLS between Caddy and Traefik**: today it would be plain HTTP from the DMZ across OPNsense into VLAN 30. Fine, but say so. (b) A missing alternative: **no public exposure at all** (WireGuard on OPNsense) or a tunnel, for services that only you use. (c) With which tool is the VM provisioned (Terraform libvirt provider, `community.libvirt`, by hand)? |
| **0004** Patch management | The rationale for the kernel blacklist doesn't hold (in-tree drivers), and *"zero-day … remediated automatically"* is not true for the kernel (R2-8). Kernel testing "in staging" conflicts with ADR-0006, where staging is AWS, which by its own admission cannot test hardware or driver issues. |
| **0005** rp_filter | The rationale is built on multi-node asymmetry (cross-node pods, NodePort on another node), but the target is single-node. The real single-node reason is multiple interfaces (VLAN 30, later `br70`, `cni0`, MetalLB VIPs). The "Dual-Stack / IPv6 ULA" consequence is **misleading**: `rp_filter` is IPv4-only, and IPv6 has no equivalent sysctl. |
| **0006** Update strategy | The core idea (Track 1 GitOps, Track 2 staged platform upgrades) is good. Issues: (a) The budget alarm is described as an existing control, but it is optional and not done in the roadmap. (b) Syncing the *whole* catalog (30+ apps) onto a `t3.small` with 2 GB is not realistic. Apps that need GPU, MetalLB L2, hostPath/mergerfs or secrets (ESO credentials in AWS?) can't be validated there. Write down a *defined subset*. (c) The "instant rollback via `git revert`" does not hold for stateful apps with DB migrations (Nextcloud, Paperless). Rollback needs a PV snapshot/backup *before* the upgrade. (d) Auto-merging patch updates of stateful apps straight to prod needs that same backup safety net. (e) `caddy:2-alpine` in the repo already breaks the ADR's own tag-pinning rule. |
| **0007** TLS SANs | Clean. But the roadmap's preferred access path (SSH tunnel, `127.0.0.1` is already in the cert) is not listed as an alternative. Then `k3s_tls_san` is unused in every inventory and 6443 is still open. Pick one: SSH tunnel and close 6443, *or* set the SAN (Terraform could write the public IP into the inventory). |

---

## 6. Roadmap & design decisions not yet implemented

### 🔴 Migration plan contradictions (Phases 5 / 8)

- Phase 5 promises to be *"completely isolated from production data"*, but contains the **in-place migration of the Unraid HDDs** (Tier 3) and the SnapRAID parity strategy.
- Phase 8 says *"Rsync large media libraries to new `mergerfs` pool"*. With in-place migration there is nothing to copy. Rsync implies new disks.
- Phase 8 *"Fallback window … preserving parity fallback"* only works if the data disks stay **read-only** for the whole window and the old parity disk is **not** reused for SnapRAID. Mounting XFS read-write once is enough to make the Unraid parity stale.

**Suggestion:** write one explicit sequence (ideally as an ADR): *disks move → read-only → apps migrate one by one (appdata rsync only) → validation → **then** read-write + SnapRAID parity computed on the old parity disk → end of fallback.* Then move Tier 3 out of Phase 5 into Phase 8.

### Phase 3: Ingress & MetalLB

- **K3s ships ServiceLB (klipper-lb).** MetalLB needs `disable: [servicelb]` in `config.yaml`, otherwise both fight over `LoadBalancer` services. That item is missing from the roadmap. Customising Traefik (trustedIPs, `externalTrafficPolicy`) should be done via `HelmChartConfig`, not by editing manifests.
- MetalLB on a single node is justified because Pi-hole (53), Omada and Traefik need **separate IPs with overlapping ports**. Good. But the pool in the roadmap is IPv4-only, while ADR-0001 also reserves an IPv6 range.
- `trustedIPs` contains `<P>:70::10/128`, which is a **GUA from the dynamic prefix**. That contradicts ADR-0001 ("GUAs are not referenced in cluster configuration"). Caddy → Traefik should use a ULA (`fd85:cc6d:b16f:70::10`) or IPv4.
- **Pi-hole on the only node** + automatic reboots at 03:00 (ADR-0004) = DNS outage for the whole network, on every reboot and on every K3s problem. Plan a secondary resolver outside the cluster (OPNsense Unbound) and announce both via DHCP.
- Omada: device discovery/adoption uses L2 broadcast. Behind a MetalLB VIP that won't work without `hostNetwork` or DHCP option 138. Test this in RemoteLab.

### Phase 4: CI/CD

- Be realistic about scope: on GitHub-hosted runners, `--syntax-check`, `ansible-lint`, `yamllint`, `terraform fmt/validate`, `tflint`, `kubeconform` (manifests) and `gitleaks` are possible. `--check --diff` needs a *reachable target*, so either AWS in the pipeline or not at all.
- "GitHub repository secrets for SSH authentication in AWS PoC" + "teardown test via pipeline" means AWS credentials in GitHub. Use **GitHub OIDC → IAM role** (no static keys), scoped to the PoC resources, and make sure fork PRs can't access it. Status of 3.4: the README makes the right promise, and this item has to keep it.
- Renovate with a regex manager for `k3s_version`/`argocd_chart_version` in Ansible defaults: good. Add the Argo CD ↔ Kubernetes compatibility check to the PR template (R2-2).

### Phase 4.5: RemoteLab

- Good gate. Add: an explicit **reboot test with the data disk detached** (R2-1), and a **24 h SLAAC test** (R2-4).
- Hyper-V can't validate `br70`, KVM or `br_netfilter` (see Phase 5). Write that down explicitly as a gap, so it doesn't look tested.

### Phase 5: Bare metal (decide **before** the first K3s start)

- **Immutable K3s settings:** `data-dir`, `cluster-cidr`/`service-cidr`, `disable: [servicelb]` (and possibly `traefik`, if you want to own it via Argo). Set these on the first boot. Changing them later means rebuilding the cluster.
- **Tier 2 is overloaded:** a single NVMe (no mirror yet) with appdata PVs **+** the K3s `data-dir` **+** the ingest/write cache for the array. That is a SPOF for everything stateful, plus mixed I/O (DB fsyncs next to media ingest). Suggestion: keep the cache on its own partition/dataset with a quota, and treat "backups exist" (Phase 7) as a precondition for Phase 5 operation, not just for Phase 8.
- **ZFS vs. Btrfs:** ZFS on Debian means DKMS, so it is tied to the kernel blacklist (R2-8). Overlayfs on ZFS only works with newer OpenZFS versions, otherwise containerd needs a different snapshotter. Btrfs (or ext4/LVM) avoids both. Record the decision in the ADR from §5.
- **`br_netfilter` vs. the DMZ bridge:** K3s loads `br_netfilter`, so bridged DMZ traffic on `br70` goes through the host's iptables `FORWARD` chain, which K3s and Flannel manage. Disabling `bridge-nf-call-iptables` globally is not an option, because K3s needs it. Plan explicit `FORWARD` accept rules for `br70` (or an nftables bridge-family table) instead. This can't be tested in RemoteLab. Test it early on the hardware.
- **VLAN reconfiguration via Ansible over the same NIC** risks locking yourself out. Have console/IPMI ready, or use the `async` + timeout-rollback pattern.

### Phase 6: GitOps & secrets

- **Chicken-and-egg:** ESO + 1Password needs *one* bootstrap secret (Connect token or service-account token) in the cluster. Decide who injects it: Ansible from `op read …`, at bootstrap time, `no_log: true`. Check whether your 1Password plan supports Connect. ESO also has a provider based on 1Password **service accounts** that does not need a Connect server.
- Argo CD admin: rather than "set the password declaratively", consider disabling the local admin after setup, or rotating the initial secret and deleting it.
- `kube-prometheus-stack` needs roughly 1.5–2 GB RAM. That's fine on bare metal, but it won't fit into the AWS staging of ADR-0006. Another reason for a defined staging subset.

### Phase 7: Day-2

- Back up databases **application-consistently** (pg_dump/mysqldump hooks), not just by file-level restic over running DB files.
- In line with review 4.4: the K3s DB backup is a nice-to-have, while the **token** (`/var/lib/rancher/k3s/server/token`) and PV data are the essentials.
- Pre-upgrade snapshot/backup as a mandatory step in the Track-1 flow (ADR-0006 rollback).

### Phase 8: Cutover

- "Router port forwardings … to new Debian host IP": according to ADR-0003, the target is the **Caddy VM** (`10.55.192.10`), not the host.

---

## 7. Top next steps

1. 🔴 Add `RequiresMountsFor` for `k3s.service` and run the reboot test with the data disk detached (R2-1).
2. 🔴 Upgrade Argo CD to 3.x while the cluster is still disposable (R2-2).
3. 🔴 Untangle the migration sequence in Phases 5/8 (in-place vs. rsync, parity fallback). Write it down as an ADR.
4. 🟠 Move shared values to `group_vars`/`host_vars`, set `node-ip` from the variable, make `accept_ra=2` explicit, remove `host_key_checking` (R2-3, R2-4, R2-7).
5. 🟠 Before Phase 5: decide the immutable K3s settings (`data-dir`, `disable: servicelb`) and the Tier-2 filesystem as ADRs, and tie the kernel-update question to them (R2-8).
6. 🟠 Fix the doc drift in §4. Add the `Proposed` status to the ADRs. Keep one roadmap instead of two.
7. 🟡 Run `ansible-lint` + `yamllint` once locally and fix what they report (R2-12). That also clears most of the old 3.8 leftovers.

> [!TIP]
> The quickest win is still the same three-step loop from review 1: `destroy && apply` → run the playbook **twice** (`changed=0`) → **reboot** (once *with* and once *without* the data disk). R2-1, R2-4 and R2-6 would all have shown up there.
