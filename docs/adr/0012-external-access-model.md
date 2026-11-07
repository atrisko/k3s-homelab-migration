# ADR-0012: External Access Model

* **Status:** Proposed
* **Date:** 2026-11-07

## Context

* All services run on a single bare-metal host, which also holds sensitive data (documents, photos, personal files).
* ADR-0003 places a Caddy VM in the DMZ (VLAN 70) as the entry point for public traffic, but does not define which services may be reached through it.
* Some external users want to watch Jellyfin on smart TVs. TVs rarely run a VPN client.
* The OPNsense firewall configuration is maintained outside this repository. This ADR records the access rules the cluster has to fit into.
* The realistic threat is automated scanning for known vulnerabilities and weak passwords, not a targeted attack.

## Decision

### 1. Internal by default

Every service is internal unless it is listed below. There are three access levels:

| Level | Path | Services | Users |
| :--- | :--- | :--- | :--- |
| **Public** | Internet → Caddy VM (VLAN 70) → Traefik | Tandoor | Anyone |
| **Guest VPN** | WireGuard on OPNsense → dedicated LoadBalancer IPs | Jellyfin, Seerr | External users |
| **Admin VPN** | WireGuard on OPNsense | All internal services, including Nextcloud | Operator |

### 2. Public services are an explicit list

* A service becomes public only by being added to the table above. Every addition amends this ADR.
* Tandoor is public as a proof of concept for the public path. Its data is not sensitive. Public registration is disabled.
* A service is taken off the internet by removing its route on the Caddy VM. The cluster, Traefik and the production revision (ADR-0011) are not touched.

### 3. Guest VPN

* Each guest gets a separate WireGuard instance on OPNsense, with its own port and interface. Revoking one guest does not affect the others, and firewall rules apply per interface.
* Guests reach only the service ports of Jellyfin and Seerr. The firewall enforces this, not the guest's device or router.
* Jellyfin and Seerr get dedicated MetalLB IPs from the LoadBalancer pool (ADR-0001) instead of sharing the Traefik IP. A rule on the Traefik IP would open every hostname behind Traefik.
* Inside the tunnel, clients use plain HTTP to the service port. Guest access does not depend on Traefik, internal DNS or certificates.
* TVs without a VPN client are connected per guest, either by a site-to-site tunnel on the guest's router that routes only the service IPs into the tunnel, or by a streaming device with a WireGuard client.

### 4. Admin VPN

* One WireGuard instance with one peer per device, so a lost device can be revoked on its own.
* It reaches the internal networks except the client VLANs of flatmates and guests. The DMZ is reachable via SSH only.

### 5. No dedicated DMZ node

Public services run on the cluster node. Isolation of workloads inside the cluster is decided in a separate ADR.

## Consequences

**Positive:**

* Only Tandoor and the Caddy VM are exposed to the internet. Services with sensitive data stay behind the VPN.
* Guest access can be revoked per person.
* No additional hardware is needed.

**Negative & Trade-offs:**

* **Guests without a VPN cannot watch Jellyfin on a TV.**
* **Site-to-site tunnels extend into networks the operator does not control.** Traffic between the TV and the guest's router is unencrypted HTTP, each site needs a subnet that does not overlap with others, and setup needs access to the guest's router.
* **One port and one interface per guest** on OPNsense.
* **The public service shares the host with sensitive data.** A compromised Tandoor pod is contained only by the measures inside the cluster, not by a separate host.
* **Firewall rules are not in Git.** OPNsense and this ADR can drift apart.
* **Nextcloud share links for external users are not available.**
* **Revisit:** If VPN access does not work for guests in practice, public access to Jellyfin is reconsidered (see alternatives).

## Alternatives Considered

* **Jellyfin public with hardening (geoblocking, CrowdSec, admin functions internal only):**
  * *Rejected for now:* Jellyfin has no built-in second factor, and TV clients do not work behind forward authentication. The admin dashboard is a client-side route, so a proxy can only block API paths, which depend on the Jellyfin version. Jellyfin needs the GPU (`/dev/dri`) and is therefore bound to the cluster node.
* **Dedicated DMZ node or VM for public services:**
  * *Rejected:* The hardware cost is out of proportion to the realistic risk. Jellyfin could not move there anyway because of the GPU.
* **Nextcloud public with 2FA or SSO:**
  * *Rejected for now:* Nextcloud holds the most sensitive data. App passwords used by the sync clients bypass 2FA, and an identity provider for SSO would itself have to be public. Can be revisited if share links for external users are needed.
* **No public service at all:**
  * *Rejected:* The public path through the Caddy VM is built and operated with a non-critical service first, so it is proven before anything more sensitive could use it.
