# Issue 0001: K3s exits once after boot: network policy controller fails to list links

* **Status:** Open (accepted as known issue)
* **Date:** 2026-11-02

## Symptom

On about every second boot, K3s shuts itself down a few seconds after startup and is restarted by systemd:

```
level=error msg="Shutdown request received: \"failed to start networking: unable to initialize network policy controller: error getting node subnet: failed to get list of links: results may be incomplete or inconsistent\""
```

First seen in [run 2](../testing/runs/2026-10-30-remotelab-2.md) (K3S-05 failed; deviations for K3S-05 and STO-06). Timeline of that boot from the k3s unit journal:

| Time | Event |
| --- | --- |
| 15:27:30 | k3s starting |
| 15:27:43 | `Started` |
| 15:27:47 | error above, shutdown request |
| 15:27:49 | unit deactivated, 14 `containerd-shim` processes left running (`KillMode=process`) |
| 15:27:54 | `Scheduled restart job, restart counter is at 1` |
| 15:28:01 | second start `Started` |

Not seen in run 1.

## Environment

- **Node:** RemoteLab (Hyper-V VM), static IPv4 via ifupdown (`auto eth0`, no DHCP), static ULA
- **OS / Kernel:** Debian 13.7 / `6.12.111+deb13-amd64`
- **K3s:** `v1.37.1+k3s1`, embedded network policy controller (kube-router)

## Measurement

10 consecutive reboots on 2026-11-02, driven from the control node. After each boot the script waits for K3s to become `active`, waits another 90 s, then records `NRestarts` and the number of journal lines with the error:

```bash
{
  HOST=alex@10.100.34.71
  for i in $(seq 1 10); do
    OLD=$(ssh "$HOST" cat /proc/sys/kernel/random/boot_id)
    ssh "$HOST" 'sudo systemctl reboot'
    until NEW=$(ssh -o ConnectTimeout=5 "$HOST" cat /proc/sys/kernel/random/boot_id 2>/dev/null) && [ "$NEW" != "$OLD" ]; do sleep 5; done
    printf 'boot %2s: ' "$i"
    ssh "$HOST" 'bash -s' <<'EOF'
timeout 300 bash -c 'until systemctl is-active -q k3s; do sleep 2; done'; W=$?
sleep 90
printf '%s wait=%s nrestarts=%s netlink=%s\n' "$(date +%H:%M:%S)" "$W" \
  "$(systemctl show k3s -p NRestarts --value)" \
  "$(sudo journalctl -b -u k3s --no-pager | grep -c 'failed to get list of links')"
EOF
  done
} | tee ~/boot-loop.txt
```

Result:

```
boot  1: 10:46:05 wait=0 nrestarts=0 netlink=0
boot  2: 10:48:08 wait=0 nrestarts=0 netlink=0
boot  3: 10:50:11 wait=0 nrestarts=0 netlink=0
boot  4: 10:52:13 wait=0 nrestarts=1 netlink=1
boot  5: 10:54:13 wait=0 nrestarts=0 netlink=0
boot  6: 10:56:17 wait=0 nrestarts=1 netlink=1
boot  7: 10:58:18 wait=0 nrestarts=1 netlink=1
boot  8: 11:00:23 wait=0 nrestarts=0 netlink=0
boot  9: 11:02:26 wait=0 nrestarts=1 netlink=1
boot 10: 11:04:27 wait=0 nrestarts=1 netlink=1
```

- Crash rate: 5 of 10 boots.
- Every crash is a single restart; the second start always succeeded.
- No silent case: the error never appeared without a restart (`nrestarts=0 netlink>0`).
- K3s was `active` well within the wait every time.

## Suspected mechanism (not verified)

The message is the text of `ErrDumpInterrupted` in `vishvananda/netlink`: the kernel flagged a netlink dump with `NLM_F_DUMP_INTR` because the link list changed while it was being read. Since netlink 1.2.1 the library returns this as an error instead of ignoring the flag. Other projects retry on it (e.g. Docker's `nlwrap`); the network policy controller apparently treats it as fatal on startup.

Open: which interfaces change at that moment. Two candidates:

- the host network stack, because without DHCP K3s starts earlier in the boot
- K3s itself, which recreates pod sandboxes (`veth`, flannel, `cni0`) during startup

No matching upstream issue found in `k3s-io/k3s` or `cloudnativelabs/kube-router`.

## Risk assessment

- **Frequency:** automatic reboots happen only when an update requires one (ADR-0004, 03:00 window), i.e. a few per month, times a crash rate of about 50 %.
- **Impact:** about 20 s of additional downtime per affected boot.
- **No permanent outage:** the k3s unit has `Restart=always`, `RestartSec=5s`, `StartLimitBurst=5`, `StartLimitIntervalSec=10s`. A crash cycle takes more than 20 s, so at most one start falls into any 10 s window and the start limit cannot be hit.

## Decision

Accepted as a known issue. K3S-07 (no restart after boot) stays failing and its roadmap item stays unchecked until this is resolved.

## Re-evaluate when

- bare metal (Phase 5, before Gate 7.5): repeat the measurement; VLAN subinterfaces, `br70` and libvirt tap devices add interfaces at boot and may raise the rate or cause consecutive crashes
- the error appears without a restart (silent case)
- a K3s release changes the netlink handling of the network policy controller

## Side observation

The restart left 14 `containerd-shim` processes running (`KillMode=process`), so the second start adopts containers from the first. Not investigated; separate topic.
