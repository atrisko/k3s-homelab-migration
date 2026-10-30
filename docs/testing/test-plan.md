# 🧪 Test Plan: K3s Homelab Migration

> **Status:** Draft · **Scope:** Roadmap Phases 1–3 (code as of commit `b4952f9`, validated on the RemoteLab in run 0)  
> **References:** [roadmap.md](../roadmap.md) · [ansible.md](../ansible.md) · [runs/](runs/)

This catalog defines **what** is verified and **how**. It changes together with the code. Executed runs are recorded separately in [`runs/`](runs/) and are never edited afterwards.

Only properties that are observable on a running system are covered. Implementation details ("which task ran") and documentation items are out of scope.

---

## Run Policy

- **Full run (documented):**
  - at the completion of each roadmap phase (milestone gate)
  - after version bumps of K3s, Argo CD chart, or Debian major release
  - after changes to the storage or network paths of `os_base`, `storage_poc`, or `k3s_install`
  - as the Pre-Migration Gate on bare metal (Phase 7.5)
- **Partial run (documented):** allowed when a change is clearly scoped (e.g. only `NET-*` after a network change). The run record states the subset and the reason.
- **Ad-hoc testing:** remains the feedback loop during feature development. It is not recorded here.
- **Environments:** each full run targets one environment and is recorded as one file. AWS runs follow the full lifecycle `terraform apply` → test → `terraform destroy` to limit cost.
- **Findings** are not fixed during a run. They are recorded in the run file and moved to the roadmap or an issue.

---

## Conventions

- Commands run **on the target node** unless marked *(control node)*.
- Expected values that depend on the commit under test (versions, IPs) are taken from the role defaults and inventory **at that commit**.
- **Session setup:** paste the following block into every new shell on the target node before running tests. This applies at the start of Block 2 and again after every reboot (Block 3, STO-06), because variables and aliases do not survive the session. On AWS, replace the `DISK` line with the commented AWS line and the volume ID from the generated inventory, because it changes with every `terraform apply`.

```bash
IF=$(ip -4 route show default | awk '{print $5}')   # primary interface
ULA=fd85:cc6d:b16f:30::10                            # node_ipv6_ula (address part)
APPDATA=/mnt/appdata                                 # appdata_path
DISK=/dev/disk/by-id/scsi-360022480eb62ad2262bbe5f495d502e6  # data_disk_device: remotelab
# DISK=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_<vol_id>  # aws: from the generated inventory
alias k='sudo k3s kubectl'
echo "IF=$IF ULA=$ULA APPDATA=$APPDATA DISK=$DISK"   # verify: no empty value
ls -l "$DISK"                                        # verify: device exists
```

- **Guarded variables:** commands reference the variables as `${VAR:?}`. If the session setup was skipped, the shell aborts with `parameter null or not set` instead of producing a misleading result (or, in Block 5, acting on `/`).
- **Copy & paste:** every command is complete and can be pasted as is. Tests are not defined by reference to other tests, even where they repeat them.
- **Exit-code checks:** tests whose pass criterion is an exit code print nothing by themselves, so their commands end with `; echo $?`. Record the printed value.
- **jsonpath output** has no trailing newline, so those commands end with `; echo`.
- **Multi-line blocks with `sudo`** are wrapped in `{ … }`. `os_base` sets `Defaults use_pty`, so `sudo` consumes input that was pasted ahead of it, and the following lines would be lost. Bash reads a `{ … }` group completely before running it. Paste the block as a whole, including the braces.

- **Env:** `aws`, `remotelab`, or `all`.
- **Block** defines the execution order: `0-infra` → `1-deploy` → `2-pre-reboot` → `3-reboot` → `4-post-reboot` → `5-destructive`.

---

## Node Preconditions

Block 1 assumes a node prepared according to [Node Preconditions](../ansible.md#node-preconditions-remotelab--bare-metal) (RemoteLab, bare metal) or provisioned by Terraform (AWS). The run record states the starting state:

- **prepared:** the prepared state before the first playbook run (e.g. a restored checkpoint). IDEM-01 then proves convergence from scratch.
- **existing:** a node that has already been provisioned by an earlier commit. IDEM-01 then proves convergence from that state.

---

## Block 0 · Infrastructure (AWS only)

### AWS-01 · IMDSv1 requests are rejected

- **Env:** aws · **Ref:** Phase 1
- **Command:** `curl -s --max-time 5 -o /dev/null -w '%{http_code}\n' http://169.254.169.254/latest/meta-data/`
- **Pass:** output is `401`
- **Note:** `000` means the metadata endpoint did not answer within 5 s (e.g. endpoint disabled or IMDSv2 hop limit). Without `--max-time`, `curl` would hang.

### AWS-02 · All attached EBS volumes are encrypted

- **Env:** aws · **Ref:** Phase 1 · *(control node)*
- **Command:**

  ```bash
  ID=$(aws ec2 describe-instances --filters Name=tag:Name,Values=K3s-PoC-Server Name=instance-state-name,Values=running \
       --query 'Reservations[0].Instances[0].InstanceId' --output text)
  aws ec2 describe-volumes --filters Name=attachment.instance-id,Values="$ID" --query 'Volumes[].Encrypted' --output text
  ```

- **Pass:** every value is `True` (root and data volume)

### AWS-03 · Ingress is restricted to the operator CIDR

- **Env:** aws · **Ref:** Phase 1, R2-11 · *(control node)*
- **Command:**

  ```bash
  aws ec2 describe-security-groups --filters Name=group-name,Values=k3s_allow_traffic \
    --query 'SecurityGroups[0].IpPermissions[].[FromPort,IpRanges[].CidrIp]' --output text
  terraform -chdir=terraform/aws-poc output -raw admin_cidr
  ```

- **Pass:** exactly ports 22, 80, 443, 6443; every CIDR equals `admin_cidr`; no `0.0.0.0/0`

### AWS-04 · SSH via generated config works

- **Env:** aws · **Ref:** Phase 1 · *(control node)*
- **Command:** `ssh -F terraform/aws-poc/ssh_config aws-k3s-poc true; echo $?`
- **Pass:** exit code 0

### AWS-05 · Infrastructure has no drift

- **Env:** aws · **Ref:** Phase 1 (AMI lifecycle guard) · *(control node)*
- **Command:** `terraform -chdir=terraform/aws-poc plan -detailed-exitcode; echo $?`
- **Pass:** exit code 0 (no changes)
- **Note:** a changed operator public IP causes a legitimate diff on `admin_cidr`; record as deviation, not failure.

---

## Block 1 · Deploy & Idempotency

### IDEM-01 · Playbook converges

- **Env:** all · **Ref:** Phase 2/3 · *(control node)*
- **Command:** `ansible-playbook -i inventory/<env>.yaml site.yaml` (from `ansible/`)
- **Pass:** PLAY RECAP shows `failed=0 unreachable=0`
- **Note:** exactly one of the two ULA persistence tasks (ifupdown / netplan) is skipped, matching the node's network stack.

### IDEM-02 · Second run reports no changes

- **Env:** all · **Ref:** Phase 2/3 · *(control node)*
- **Command:** `ansible-playbook -i inventory/<env>.yaml site.yaml --diff` (from `ansible/`), immediately after IDEM-01
- **Pass:** PLAY RECAP shows `changed=0 failed=0`; every `changed` task is recorded by name as deviation
- **Note:** `--diff` shows changes only for modules with diff support (e.g. `copy`, `template`, `lineinfile`). Modules such as `sysctl`, `command` or `systemd` report `changed` without a diff; check the affected value directly on the node.

---

## Block 2 · Pre-Reboot (runtime activation, loaded state)

### NET-01 · ULA is active at runtime

- **Env:** all · **Ref:** Phase 2, ADR-0001
- **Command:** `ip -6 addr show dev "${IF:?}" to "${ULA:?}/128" | grep -q inet6; echo $?`
- **Pass:** exit code 0

### NET-02 · Exactly one network stack carries the ULA config

- **Env:** all · **Ref:** R2-5
- **Command:**
  - remotelab (ifupdown): `test -f /etc/network/interfaces.d/60-ula.cfg && test ! -e /etc/netplan/60-ula.yaml; echo $?`
  - aws (netplan): `test -f /etc/netplan/60-ula.yaml && test ! -e /etc/network/interfaces.d/60-ula.cfg; echo $?`
- **Pass:** exit code 0

### SYS-01 · Kernel hardening sysctls are active

- **Env:** all · **Ref:** Phase 2, ADR-0005
- **Command:** `/usr/sbin/sysctl -n net.ipv4.conf.all.rp_filter kernel.dmesg_restrict kernel.kptr_restrict kernel.sysrq net.ipv4.ip_forward net.ipv6.conf.all.forwarding | paste -sd' '`
- **Pass:** output is `2 1 2 0 1 1`

### SYS-02 · Router advertisements are accepted despite forwarding

- **Env:** all · **Ref:** R2-4
- **Command:** `/usr/sbin/sysctl -n net.ipv6.conf.all.accept_ra net.ipv6.conf.default.accept_ra net.ipv6.conf.${IF:?}.accept_ra | paste -sd' '`
- **Pass:** output is `2 2 2`

### SYS-03 · SSH rejects password authentication

- **Env:** all · **Ref:** Phase 2 · *(control node)*
- **Command:**
  - remotelab: `ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password alex@10.100.34.71 true; echo $?`
  - aws: `ssh -F terraform/aws-poc/ssh_config -o PubkeyAuthentication=no -o PreferredAuthentications=password aws-k3s-poc true; echo $?`
- **Pass:** login fails with `Permission denied (publickey)` (exit code 255)
- **Note:** tests the running daemon, not the config file.

### SYS-04 · journald runs with the configured size limit

- **Env:** all · **Ref:** Phase 2
- **Command:** `sudo journalctl -b -u systemd-journald --no-pager | grep 'System Journal' | tail -1`
- **Pass:** latest line contains `max 1G` (`os_systemd_max_usage`)
- **Note:** `sudo` is required, because the admin user is not in `adm` or `systemd-journal`. Without it, `grep` finds nothing. The filter on `System Journal` excludes the `Runtime Journal` line (`/run`, limited by `RuntimeMaxUse`), which journald logs early at boot before switching to persistent storage.

### SYS-05 · Blacklisted kernel modules cannot be loaded

- **Env:** all · **Ref:** Phase 2
- **Command:** `sudo modprobe -n -v dccp`
- **Pass:** output is `install /bin/true`

### SYS-06 · Unattended-upgrades policy is effective

- **Env:** all · **Ref:** ADR-0004, R2-8
- **Command:** `apt-config dump | grep -E '^Unattended-Upgrade::(Origins-Pattern|Package-Blacklist|Automatic-Reboot)'`
- **Pass:** only `label=Debian-Security` origin; no `Package-Blacklist` line (an empty list does not appear in `apt-config dump`); `Automatic-Reboot "true"`; `Automatic-Reboot-Time "03:00"`

### STO-01 · Appdata volume is mounted from the declared device

- **Env:** all · **Ref:** Phase 2
- **Command:** `[ "$(findmnt -n -o SOURCE --mountpoint "${APPDATA:?}")" = "$(readlink -f "${DISK:?}")" ]; echo $?`
- **Pass:** exit code 0

### STO-02 · Storage guard is loaded in the running systemd manager

- **Env:** all · **Ref:** R2-1
- **Command:** `systemctl show k3s.service -p RequiresMountsFor -p NeedDaemonReload`
- **Pass:** `RequiresMountsFor=/mnt/appdata` and `NeedDaemonReload=no`

### K3S-01 · Pinned K3s version is installed

- **Env:** all · **Ref:** Phase 3, R2-6
- **Command:** `k3s --version | head -1`
- **Pass:** contains `k3s_version` from `k3s_install/defaults/main.yaml`

### K3S-02 · Node registers dual-stack internal IPs

- **Env:** all · **Ref:** Phase 3, ADR-0001, R2-3
- **Command:** `k get nodes -o jsonpath='{range .items[*].status.addresses[?(@.type=="InternalIP")]}{.address}{" "}{end}'; echo`
- **Pass:** contains `node_ipv4` and `$ULA`

### K3S-03 · Local-path provisioner targets the appdata volume

- **Env:** all · **Ref:** Phase 3
- **Command:** `k -n kube-system get cm local-path-config -o jsonpath='{.data.config\.json}'; echo`
- **Pass:** `paths` contains `/mnt/appdata`

### K3S-04 · Pinned Argo CD chart is deployed

- **Env:** all · **Ref:** Phase 3, R2-2
- **Command:** `k -n argocd get deploy argocd-server -o jsonpath='{.metadata.labels.helm\.sh/chart}'; echo`
- **Pass:** equals `argo-cd-<argocd_chart_version>`

### GITOPS-03 · Root application has no cascading finalizer

- **Env:** all · **Ref:** R2-9
- **Command:** `k -n argocd get application root-application -o jsonpath='{.metadata.finalizers}'; echo`
- **Pass:** output is empty

---

## Block 3 · Reboot

### REBOOT-01 · Node reboots and returns

- **Env:** all
- **Command:** `sudo systemctl reboot`; wait for SSH; repeat the session setup; then `sudo journalctl --list-boots | tail -2`
- **Pass:** SSH reachable again; the boot with index `0` starts right after the previous boot (`-1`) ends, at the time of the reboot
- **Note:** the boot list can be checked afterwards, so no value has to be recorded before the reboot.

---

## Block 4 · Post-Reboot (persistence)

### NET-03 · ULA persists across reboot

- **Env:** all · **Ref:** Phase 2, ADR-0001
- **Command:** `ip -6 addr show dev "${IF:?}" to "${ULA:?}/128" | grep -q inet6; echo $?`
- **Pass:** exit code 0

### NET-04 · SLAAC works under forwarding after reboot

- **Env:** baremetal · **Ref:** ADR-0001 (decision 6), R2-4
- **Command:**

  ```bash
  ip -6 addr show dev "${IF:?}" scope global dynamic | grep -q inet6; echo $?
  ip -6 route show default | grep -q "dev ${IF:?}"; echo $?
  ```

- **Pass:** both print `0`: a SLAAC address (`dynamic`, i.e. with a lifetime from the router advertisement) and an IPv6 default route on the primary interface
- **Note:** neither AWS nor the RemoteLab has IPv6 router advertisements, so this test exists only for bare metal. SYS-08 checks the setting (`accept_ra=2`), NET-04 its effect.

### SYS-07 · Hardening sysctls persist

- **Env:** all · **Ref:** Phase 2
- **Command:** `/usr/sbin/sysctl -n net.ipv4.conf.all.rp_filter kernel.dmesg_restrict kernel.kptr_restrict kernel.sysrq net.ipv4.ip_forward net.ipv6.conf.all.forwarding | paste -sd' '`
- **Pass:** output is `2 1 2 0 1 1`

### SYS-08 · accept_ra persists on all scopes

- **Env:** all · **Ref:** R2-4
- **Command:** `/usr/sbin/sysctl -n net.ipv6.conf.all.accept_ra net.ipv6.conf.default.accept_ra net.ipv6.conf.${IF:?}.accept_ra | paste -sd' '`
- **Pass:** output is `2 2 2`

### SYS-09 · Time sync and update timers are enabled and active

- **Env:** all · **Ref:** Phase 2, ADR-0004
- **Command:**

  ```bash
  systemctl is-enabled systemd-timesyncd apt-daily.timer apt-daily-upgrade.timer \
    && systemctl is-active systemd-timesyncd apt-daily.timer apt-daily-upgrade.timer \
    && timeout 300 bash -c 'until [ "$(timedatectl show -p NTPSynchronized --value)" = yes ]; do sleep 5; done'; echo $?
  ```

- **Pass:** exit code 0
- **Note:** right after boot, the first NTP sync can take a while; the command waits up to 300 s for it. Exit code `124` means the clock was not synchronized within that time.

### STO-03 · Appdata mount persists via fstab

- **Env:** all · **Ref:** Phase 2
- **Command:**

  ```bash
  findmnt -n -o SOURCE,OPTIONS,PASSNO --fstab --target "${APPDATA:?}"
  [ "$(findmnt -n -o SOURCE --mountpoint "${APPDATA:?}")" = "$(readlink -f "${DISK:?}")" ]; echo $?
  ```

- **Pass:** fstab source is the `/dev/disk/by-id/…` path, options include `nofail`, fsck pass field is `2`; the second command prints `0`

### K3S-05 · K3s is up and the node is Ready

- **Env:** all · **Ref:** Phase 3
- **Command:** `systemctl is-active k3s && k wait --for=condition=Ready node --all --timeout=180s; echo $?`
- **Pass:** exit code 0

### GITOPS-01 · Root application is Synced and Healthy

- **Env:** all · **Ref:** Phase 3
- **Command:** `k -n argocd get application root-application -o jsonpath='{.status.sync.status} {.status.health.status}'; echo`
- **Pass:** output is `Synced Healthy`

### GITOPS-02 · Smoke-test workload serves HTTP

- **Env:** all · **Ref:** Phase 3
- **Command:**

  ```bash
  k -n default rollout status deploy/caddy-test --timeout=180s \
    && IP=$(k -n default get svc caddy-test-svc -o jsonpath='{.spec.clusterIP}') \
    && timeout 120 bash -c "until curl -sf -o /dev/null http://$IP; do sleep 5; done" \
    && curl -s -o /dev/null -w '%{http_code}\n' "http://$IP"
  ```

- **Pass:** rollout complete and output is `200`
- **Note:** shortly after boot, `rollout status` can report complete before the ClusterIP is reachable (run 1: `000` once, `200` 44 s later). The command retries for up to 120 s; exit code `124` without output means the service never answered.

### K3S-06 · Pods receive dual-stack addresses

- **Env:** all · **Ref:** Phase 3, ADR-0001
- **Command:** `k -n default get pods -l app=caddy-test -o jsonpath='{.items[0].status.podIPs[*].ip}'; echo`
- **Pass:** one address from `10.42.0.0/16` and one from `fd85:cc6d:b16f:4200::/56`

### IDEM-03 · Playbook reports no changes after reboot

- **Env:** all · **Ref:** Phase 2/3 · *(control node)*
- **Command:** `ansible-playbook -i inventory/<env>.yaml site.yaml --diff` (from `ansible/`)
- **Pass:** PLAY RECAP shows `changed=0 failed=0`; every `changed` task is recorded by name as deviation
- **Note:** runs **last** in Block 4. The playbook sets values at runtime and would mask persistence failures in the tests above. A failed persistence test in Block 4 is expected to show up here as `changed` (e.g. a failed SYS-08 as `changed` on "Set accept_ra at runtime"). The result is still `fail`, because the pass criterion is not met. The note names the persistence test as the cause, e.g. "consequence of SYS-08, not a separate idempotency defect".
- **Note:** `--diff` shows changes only for modules with diff support (e.g. `copy`, `template`, `lineinfile`). Modules such as `sysctl`, `command` or `systemd` report `changed` without a diff; check the affected value directly on the node.

---

## Block 5 · Destructive (end of run, with recovery)

### GITOPS-04 · Argo CD self-heals a deleted workload

- **Env:** all · **Ref:** Phase 3 (`selfHeal: true`)
- **Command:**

  ```bash
  k -n default delete deploy caddy-test \
    && timeout 300 bash -c 'until sudo k3s kubectl -n default get deploy caddy-test >/dev/null 2>&1; do sleep 5; done'; echo $?
  ```

- **Pass:** exit code 0 (deployment recreated within 300 s); afterwards the GITOPS-02 check prints `200`:

  ```bash
  k -n default rollout status deploy/caddy-test --timeout=180s \
    && IP=$(k -n default get svc caddy-test-svc -o jsonpath='{.spec.clusterIP}') \
    && timeout 120 bash -c "until curl -sf -o /dev/null http://$IP; do sleep 5; done" \
    && curl -s -o /dev/null -w '%{http_code}\n' "http://$IP"
  ```

- **Recovery:** if not recreated, trigger a manual sync:
  `k -n argocd patch application root-application --type merge -p '{"operation":{"sync":{}}}'`

### STO-04 · K3s is stopped when the appdata mount is stopped via systemd

- **Env:** all · **Ref:** R2-1 (`RequiresMountsFor=`)
- **Command:**

  ```bash
  {
    UNIT=$(systemd-escape --path --suffix=mount "${APPDATA:?}")
    systemctl show k3s.service -p Requires -p After     # precondition
    sudo systemctl stop "$UNIT"; echo $?
    systemctl is-active k3s
  }
  ```

- **Pass:** precondition: `Requires=` and `After=` contain `$UNIT`; the stop job succeeds; `systemctl is-active k3s` returns `inactive`
- **Note:** with `KillMode=process`, containers survive the K3s stop. If a workload holds files on the volume, the unmount fails with "target is busy". Record as deviation.
- **Recovery:** `sudo systemctl start "$UNIT" k3s`, then check:

  ```bash
  {
    [ "$(findmnt -n -o SOURCE --mountpoint "${APPDATA:?}")" = "$(readlink -f "${DISK:?}")" ]; echo $?   # STO-01: 0
    systemctl is-active k3s && k wait --for=condition=Ready node --all --timeout=180s; echo $?        # K3S-05: 0
    k -n default rollout status deploy/caddy-test --timeout=180s \
      && IP=$(k -n default get svc caddy-test-svc -o jsonpath='{.spec.clusterIP}') \
      && timeout 120 bash -c "until curl -sf -o /dev/null http://$IP; do sleep 5; done" \
      && curl -s -o /dev/null -w '%{http_code}\n' "http://$IP"  # GITOPS-02: 200
  }
  ```

### STO-05 · Root disk stays write-protected when the mount disappears outside systemd

- **Env:** all · **Ref:** R2-1 (`chattr +i`)
- **Command:**

  ```bash
  {
    sudo umount -l "${APPDATA:?}"
    findmnt --mountpoint "${APPDATA:?}"; echo $?              # precondition
    lsattr -d "${APPDATA:?}"                                  # precondition
    sudo touch "${APPDATA:?}"/guard-test
    ls -A "${APPDATA:?}"
  }
  ```

- **Pass:** precondition: `findmnt` exits with `1`, `lsattr` shows the `i` flag; `sudo touch` fails with `Operation not permitted`; `ls -A` prints nothing
- **Note:** `sudo` is required. Without it, `touch` fails on regular permissions (`Permission denied`) and the flag is not tested. Record whether `k3s` stays active after the lazy unmount.
- **Recovery:** if `guard-test` was created (fail), remove it first. Then `sudo mount "${APPDATA:?}"` (uses the fstab entry); start `k3s` if it is inactive (`sudo systemctl start k3s`). Then check:

  ```bash
  {
    [ "$(findmnt -n -o SOURCE --mountpoint "${APPDATA:?}")" = "$(readlink -f "${DISK:?}")" ]; echo $?   # STO-01: 0
    systemctl is-active k3s && k wait --for=condition=Ready node --all --timeout=180s; echo $?        # K3S-05: 0
    k -n default rollout status deploy/caddy-test --timeout=180s \
      && IP=$(k -n default get svc caddy-test-svc -o jsonpath='{.spec.clusterIP}') \
      && timeout 120 bash -c "until curl -sf -o /dev/null http://$IP; do sleep 5; done" \
      && curl -s -o /dev/null -w '%{http_code}\n' "http://$IP"  # GITOPS-02: 200
  }
  ```

### STO-06 · Node boots without the data disk

- **Env:** all · **Ref:** Phase 2 (`nofail`), R2-1
- **Preparation:** shut down the node; remove the data disk (Hyper-V: VM settings · AWS: `aws ec2 detach-volume`); start the node
- **Command:**

  ```bash
  {
    findmnt --mountpoint "${APPDATA:?}"; echo $?
    sleep 120                                            # wait for the device timeout (default 90 s)
    systemctl is-active k3s
    sudo journalctl -b -u k3s --no-pager | grep 'Dependency failed'
    lsattr -d "${APPDATA:?}"
    sudo touch "${APPDATA:?}"/guard-test
    systemctl is-system-running
  }
  ```

- **Pass:** all of the following:
  1. SSH is reachable (`nofail`: no emergency mode)
  2. `findmnt` exits with `1`
  3. `systemctl is-active k3s` is not `active`; the journal shows `Dependency failed` (unit dependency)
  4. `lsattr` shows the `i` flag; `sudo touch` fails with `Operation not permitted` (`chattr +i`)
- **Note:** `is-system-running` is not a pass criterion. Run 0 showed `running`, not `degraded`: units that are skipped because of a failed dependency stay `inactive` and are not counted as `failed`. A node in this state therefore looks healthy to checks based on failed units. In the session setup, `ls -l "$DISK"` fails as expected, because the disk is missing; `DISK` itself must still be set for the recovery check.
- **Recovery:** shut down the node; re-attach the **same** disk (same VHDX file / same EBS volume as `/dev/sdf`); start the node; repeat the session setup. Then check (STO-01 also proves the `by-id` path survived):

  ```bash
  {
    [ "$(findmnt -n -o SOURCE --mountpoint "${APPDATA:?}")" = "$(readlink -f "${DISK:?}")" ]; echo $?   # STO-01: 0
    systemctl is-active k3s && k wait --for=condition=Ready node --all --timeout=180s; echo $?        # K3S-05: 0
    k -n default rollout status deploy/caddy-test --timeout=180s \
      && IP=$(k -n default get svc caddy-test-svc -o jsonpath='{.spec.clusterIP}') \
      && timeout 120 bash -c "until curl -sf -o /dev/null http://$IP; do sleep 5; done" \
      && curl -s -o /dev/null -w '%{http_code}\n' "http://$IP"  # GITOPS-02: 200
  }
  ```

---

## Not Covered (intentional)

- Package list of `os_base` (implicitly covered by IDEM-01)
- sudoers hardening, remaining sshd options (`MaxAuthTries`, `ClientAlive*`)
- Fail-fast assertions in the roles (no supported network stack, missing mount), since they need a deliberately broken node
- AWS Budget Alert (not implemented yet)
- Remote API access via TLS SANs / SSH port forwarding (ADR-0007), until kubeconfig export (Phase 3, open) is in place
