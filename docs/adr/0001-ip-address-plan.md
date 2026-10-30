# ADR-0001: IP Address Plan (Dual-Stack)

* **Status:** Accepted
* **Date:** 2026-10-14
* **Amended:** 2026-10-30 (decision 6: static IPv4 on persistent nodes)

## Context

The K3s cluster will run on a single Debian node in the home network. Several
constraints shape the addressing scheme:

* **Dual-stack cannot be enabled later.** K3s fixes `cluster-cidr` and
  `service-cidr` when the cluster is first started. Switching an IPv4-only
  cluster to dual-stack afterwards is unsupported and would mean rebuilding it.
* **The home network is segmented into VLANs** (OPNsense). The node will live in
  the server VLAN, so its addresses must be planned together with all other
  VLANs to avoid overlaps. The full network plan is maintained outside this
  repository; this ADR only covers the parts relevant to K3s.
* **The ISP prefix is dynamic.** Telekom FTTH delegates a `/56` via DHCPv6-PD,
  and this prefix can change. A node address derived from it would change too,
  which K3s does not tolerate well (`node-ip`).
* **The environments differ** (AWS PoC, RemoteLab, bare metal), but the K3s
  configuration should stay identical across them. Only variables may differ.

## Decision

1. **Use dual-stack from the start**, with IPv4 and IPv6 for pods and services.
2. **Use a ULA prefix for everything internal and stable.** The prefix was
   generated randomly once (as recommended by RFC 4193) and never changes:

   `fd85:cc6d:b16f::/48`

3. **Use the VLAN ID as IPv6 subnet ID** (e.g. VLAN 30 → `fd85:cc6d:b16f:30::/64`).
4. **Use the ULA as `node-ip`.** The public GUA addresses (from the Telekom
   prefix) are used only for internet access and are not referenced in
   cluster configuration.
5. **Keep the K3s networks outside of all VLAN ranges** and reserve them
   explicitly:

| Purpose | IPv4 | IPv6 |
| :--- | :--- | :--- |
| Server VLAN 30 | `10.55.64.0/24` | `fd85:cc6d:b16f:30::/64` |
| K3s node | `10.55.64.10` | `fd85:cc6d:b16f:30::10` |
| Pods (`cluster-cidr`) | `10.42.0.0/16` | `fd85:cc6d:b16f:4200::/56` |
| Services (`service-cidr`) | `10.43.0.0/16` | `fd85:cc6d:b16f:4300::/112` |
| LoadBalancer pool (reserved) | `10.55.64.200–249` | `fd85:cc6d:b16f:30::200–249` |

6. **Configure IPv4 statically on persistent nodes** (RemoteLab, bare metal),
   with `auto <iface>` instead of `allow-hotplug <iface>` in ifupdown. AWS keeps
   DHCP, which is handled there by netplan and systemd-networkd.
   * On Debian 13, ifupdown runs **dhcpcd** for `inet dhcp`. dhcpcd takes over
     router advertisements itself and sets `accept_ra=0` on the interface after
     every reboot (run 1, SYS-08). With forwarding enabled, the kernel then
     ignores router advertisements, which prevents SLAAC and the IPv6 default
     route. The RemoteLab has no IPv6 router, so only `accept_ra=0` was
     observed; the effect on SLAAC is verified on bare metal (NET-04). Without
     `inet dhcp`, dhcpcd does not run.
   * With `allow-hotplug`, the interface is brought up by `ifup@<iface>.service`
     and not by `networking.service`, so `network-online.target` (and K3s
     behind it) does not wait for it. `auto` makes the dependency explicit.

## Consequences

**Positive**

* The cluster never needs to be rebuilt to gain IPv6.
* A change of the ISP prefix does not affect K3s, pods, services or internal
  firewall rules.
* Addresses are self-explanatory: the VLAN ID is visible in the IPv6 address.
* The random prefix avoids collisions when networks are connected later (VPN).

**Negative / trade-offs**

* Each node needs **both** a static ULA and (via SLAAC) a GUA. The ULA must be
  configured persistently on the node, not with a runtime-only `ip addr add`.
* IPv6 forwarding (`net.ipv6.conf.all.forwarding = 1`) disables SLAAC router advertisements by default unless `accept_ra = 2` is explicitly configured on the interface.
* Public reachability over IPv6 requires extra work: dynamic DNS (AAAA record)
  and a firewall alias that follows the changing prefix.
* Internal traffic often prefers IPv4 over ULA (RFC 6724), so IPv6 may be
  used less than expected in everyday tests.
* The Pod CIDR `fd85:cc6d:b16f:4200::/56` and Service CIDR
  `fd85:cc6d:b16f:4300::/112` must never be assigned to a VLAN.
* Static IPv4 on persistent nodes is a manual node precondition
  ([ansible.md](../ansible.md#node-preconditions-remotelab--bare-metal)). A DHCP
  reservation is no longer sufficient for ifupdown nodes.

## Alternatives considered

* **IPv4-only for now.** Rejected: dual-stack cannot be added later without
  rebuilding the cluster.
* **GUA as `node-ip`.** Rejected: the delegated prefix is dynamic.
* **Well-known ULA prefixes (`fd00::/8`, `fd42::/16`).** Rejected: very common
  in examples and devices, which defeats the collision protection.
* **IPv6 NAT for a ULA-only setup.** Rejected: considered bad practice and
  unnecessary with a GUA available.

## Open points

* Verify in OPNsense that the delegated prefix is a `/56` (Prefix IDs `0x10`–`0x70`).
* Decide how the reverse proxy is exposed (DMZ VM vs. other options) in a separate
  ADR ([ADR-0003](0003-caddy-instance-in-vm-as-reverse-proxy.md)).
