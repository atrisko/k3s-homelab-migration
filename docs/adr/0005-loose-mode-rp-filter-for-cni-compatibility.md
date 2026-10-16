# ADR-0005: Loose-Mode Reverse Path Filtering (rp_filter) for Kubernetes CNI Compatibility

* **Status:** Accepted
* **Date:** 2026-10-15

## Context

Standard Linux security baselines and compliance benchmarks (such as the CIS Linux Benchmark and BSI guidelines) consistently recommend configuring Linux kernel Reverse Path Filtering in strict mode:
```ini
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
```

Reverse Path Filtering (`rp_filter`) is designed to mitigate IP address spoofing by validating that an incoming packet's source address is reachable via the exact interface on which it was received. The Linux kernel supports three modes:
* `0` (Disabled): No source address validation.
* `1` (Strict Mode): The packet is silently dropped unless the incoming interface is the single best return path for the source IP according to the local routing table.
* `2` (Loose Mode): The packet is accepted as long as the source IP is reachable via *any* interface on the system according to the routing table.

### The Kubernetes Problem with Strict Mode

Kubernetes host nodes utilize container network interfaces (CNI), overlay networks (Flannel VXLAN/Host-GW), virtual ethernet pairs (`veth`), and proxy routing mechanisms (`kube-proxy`, NodePort, LoadBalancers, and Ingress controllers). 

In this architecture, network paths are frequently **asymmetric**:
* Ingress traffic may enter through physical interface `eth0`, get routed to a pod on another node via an overlay interface (`flannel.1`), and have its response handled along a different path.
* NodePort requests often arrive at one node and are forwarded to a pod hosted on a secondary node.

When strict mode (`1`) is enabled, the host kernel flags this legitimate asymmetric container traffic as spoofed and **silently drops the packets**. This causes intermittent, difficult-to-diagnose connection timeouts for cluster workloads, cross-node pod communication, and external Ingress routing.

## Decision

We deliberately configure Reverse Path Filtering in **Loose Mode (`2`)** across all network interfaces in `/etc/sysctl.d/99-kubernetes-hardening.conf`:

```ini
# Network Anti-Spoofing (Loose mode for CNI/Flannel compatibility)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
```

By choosing Loose Mode, the kernel ensures the packet's source IP is known and routable on the system, while permitting asymmetric routing paths inherent to container overlays.

## Consequences

**Positive:**
* **Reliable Container Networking:** Prevents silent packet drops during cross-node pod communication, Flannel overlay routing, NodePort proxying, and Ingress traffic.
* **Basic Anti-Spoofing Intact:** Still validates that incoming source IPs are routable on the host, rejecting completely unroutable/invalid forged source addresses (unlike mode `0`).
* **Deterministic Dual-Stack Behavior:** Works seamlessly alongside host IPv4 interfaces and our IPv6 ULA island setup (ADR-0001).

**Negative & Trade-offs:**
* **Broader Acceptance Window:** An attacker within a shared Layer-2 network could theoretically send packets with source addresses belonging to other interfaces on the same host, which loose mode does not discard. In our homelab environment, perimeter firewalls and isolated VLANs mitigate this risk.

## Alternatives Considered

* **Strict Mode (`rp_filter = 1`):**
  * *Rejected:* Incompatible with Kubernetes container networking. Causes silent packet drops and network instability across pods and Ingress controllers.
* **Disabled Mode (`rp_filter = 0`):**
  * *Rejected:* Disables source verification entirely, leaving the system unnecessarily vulnerable to trivial IP spoofing.
* **Per-Interface Overrides (Strict on `eth0`, Loose on `flannel.*`):**
  * *Rejected:* Operationally fragile. The Linux kernel computes the effective `rp_filter` as the maximum (`max()`) between `all` and the specific interface. Setting `all=1` would override virtual interfaces. Additionally, container virtual interfaces (`veth*`) are created dynamically, making static per-interface management prone to race conditions.
