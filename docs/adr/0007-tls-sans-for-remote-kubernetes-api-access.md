# ADR-0007: Declarative TLS Subject Alternative Names (SANs) for Remote Kubernetes API Access

* **Status:** Accepted
* **Date:** 2026-10-19

## Context

K3s runs an embedded Kubernetes API server that generates a self-signed TLS serving certificate (`serving-kube-apiserver.crt`) upon first startup. By default, K3s populates the certificate's Subject Alternative Names (SANs) only with:
* Local loopback addresses (`127.0.0.1`, `::1`, `localhost`)
* Cluster-internal Service DNS names (`kubernetes`, `kubernetes.default`, `kubernetes.default.svc.cluster.local`)
* The cluster Service CIDR gateway IP (e.g. `10.43.0.1`)
* The primary host IP and internal hostname discovered at launch time.

In our multi-environment deployment strategy (Phase 1 AWS Cloud PoC, Phase 4.5 Hyper-V RemoteLab, and final Bare-Metal production behind OPNsense), operators and automation tools interact with the cluster remotely across network boundaries:
* Remote administrative workstations connecting via local DNS names (e.g. `k3s.test.local` or `k3s.homelab.lan`)
* WireGuard/Tailscale VPN VIPs
* Dynamic public IP addresses or jump-host proxies.

If `kubectl` or an external API client connects to the server using an IP or DNS name not listed in the certificate's SAN extension, the client immediately terminates the connection with an `x509: certificate is valid for ..., not <target>` validation error.

Bypassing this via `insecure-skip-tls-verify: true` disables transport security validation and exposes administrative traffic to Man-in-the-Middle (MITM) risks. Furthermore, hardcoding hostnames into the base deployment role would couple the role to a single environment.

## Decision

We parameterize TLS Subject Alternative Names declaratively through Ansible and K3s's native configuration file:

1. **Role Parameterization:** Define an overridable list variable (`k3s_tls_san: []`) in `roles/k3s_install/defaults/main.yaml`.
2. **Declarative K3s Configuration:** Render the configured SANs into `/etc/rancher/k3s/config.yaml` (`tls-san:` list).
3. **Automated Certificate Regeneration via Handler:** Wire changes in `config.yaml` to an Ansible handler (`Restart k3s`). Upon restart, K3s detects new SANs and automatically re-issues the API server serving certificate.
4. **Environment-Specific Overrides:** Environments supply their respective external DNS names or IPs via inventory variables without modifying the core role.

## Consequences

**Positive:**
* **Robust Transport Security:** Remote administrative access over `kubectl` succeeds with full TLS validation; no `--insecure-skip-tls-verify` workaround required.
* **Declarative Single Source of Truth:** All node parameters remain in `/etc/rancher/k3s/config.yaml`, avoiding fragmented systemd unit overrides or CLI flags in `INSTALL_K3S_EXEC`.
* **Automated Certificate Lifecycle:** Updating `k3s_tls_san` automatically regenerates the server certificate via the reactive systemd handler without requiring manual file deletions in `/var/lib/rancher/k3s/server/tls/`.
* **Multi-Environment Isolation:** Staging (RemoteLab), Cloud (AWS), and Bare-Metal production can declare completely different domains and IPs cleanly.

**Negative / Trade-offs:**
* Modifying `k3s_tls_san` triggers a K3s service restart, resulting in a brief API control-plane downtime of 3–5 seconds (workloads and pods remain unaffected).
* Only valid IP addresses and RFC-compliant hostnames must be supplied to prevent certificate parsing errors.

## Alternatives considered

* **Client-Side `insecure-skip-tls-verify`:** Rejected due to unacceptable security risks (MITM vulnerability on administrative credentials).
* **Imperative CLI Flags via `INSTALL_K3S_EXEC`:** Rejected because it scatters configuration into `/etc/systemd/system/k3s.service.env` rather than maintaining a centralized declarative `/etc/rancher/k3s/config.yaml`.
* **SSH Port Forwarding (Tunneling):** Accessing the cluster via `ssh -L 6443:localhost:6443` connects to `127.0.0.1`, which is already included in default certificates. While valid and used as our primary access path for the ephemeral AWS PoC (allowing port 6443 to remain closed externally), declarative SAN support remains necessary for direct LAN and VPN access on bare metal without requiring background SSH sessions.
* **External Reverse Proxy for API Server:** Rejected as over-engineering for Day-1 provisioning; K3s natively handles dynamic SAN extension and certificate rotation out of the box.
