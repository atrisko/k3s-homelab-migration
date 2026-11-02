# Run 2026-11-02 · remotelab

- **Commit:** `45b5964`
- **Environment:** remotelab
- **Starting state:** existing (`25293ea`)
- **K3s:** `k3s version v1.37.1+k3s1 (356c0254)` · **Argo CD chart:** `10.10.5`
- **OS / Kernel:** `Debian 13.7` / `6.12.111+deb13-amd64`
- **Scope:** subset: `REBOOT-01, K3S-05, K3S-07, STO-05` (reason: catalog changes after run 2 (K3S-05 split, K3S-07 new, STO-05 criterion changed); code unchanged since `25293ea`)

| ID | Result | Note |
| --- | --- | --- |
| REBOOT-01 | pass | pre-check 12:04:30: `k3s` `active`. Reboot issued 12:04:47 CET; boot `-1` ends 12:04:52, boot `0` starts 12:05:04; SSH back at 12:05:09. Session setup: `DISK` → `../../sda` (was `sdb` before the reboot; the `by-id` path is unchanged) |
| K3S-05 | pass | started 12:05:09, directly after the REBOOT-01 check: `node/homelab condition met`, exit `0` at 12:05:20 |
| K3S-07 | pass | 12:05:20, directly after K3S-05: `NRestarts` `0`. The crash from [Issue 0001](../../issues/0001-k3s-boot-crash-netlink.md) did not occur on this boot, so the journal check was not run |
| STO-05 | pass | `umount -l` at 12:05:31; precondition: `findmnt` exit `1`, `lsattr` shows `----i---------e-------`; `sudo touch` → `Operation not permitted`; `ls -A` empty; wait exit `0`, then `inactive` (12:05:35). Recovery: no `guard-test` to remove; `sudo mount` exit `0` (12:05:43), `sudo systemctl start k3s` exit `0`; check at 12:05:50: STO-01 `0`, K3S-05 `0`, K3S-07 `0`, rollout complete, GITOPS-02 `200` (12:05:51) |

## Deviations & Findings

- Preparation: the first `git pull --ff-only` at 12:02:28 ended at `f945073`, the commit before the expected one. The operator interrupted, pulled again, and told me to continue; the second pull at 12:04:15 reported `Already up to date` with HEAD `45b5964` (adds K3S-07 to all recovery blocks). The run tested `45b5964`. → roadmap / issue: none
- Execution: as instructed by the operator, every step ran as a script copied with `scp` to `/tmp` on the node and executed with `ssh … bash /tmp/<file> </dev/null`, each with the session setup in the same call, preceded by `shopt -s expand_aliases`. The scripts also printed timestamps with `date` and section markers. The catalog commands were otherwise unchanged. The scripts were removed from the node at 12:06:03. → roadmap / issue: none
- `K3S-07`: passed on this single boot. That matches [Issue 0001](../../issues/0001-k3s-boot-crash-netlink.md) (crash on about every second boot) and does not resolve it. → roadmap / issue: [Issue 0001](../../issues/0001-k3s-boot-crash-netlink.md) (unchanged)

## Pre-run findings

None.
