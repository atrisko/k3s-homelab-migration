# ADR-0003: Caddy Instance in VM as Reverse Proxy

* **Status:** Proposed
* **Date:** 2026-10-14

## Context

In the final setup with K3s on bare metal, a DMZ will be utilized to expose services to the internet. To stay in line with the principle of separation of concerns, a dedicated VM will be used to run the Caddy reverse proxy, which will be responsible for TLS certificate management (Let's Encrypt) and routing traffic to the K3s cluster. K3s's Traefik ingress controller will be used to route traffic within the cluster, handle internal load balancing, and expose services under domains within the local network.

## Decision

Deploy a lightweight Caddy instance in a dedicated VM on the DMZ VLAN to serve as the entry point for all external traffic. This VM will run on KVM on the same host as the K3s cluster, but on a separate VLAN (VLAN 70 - DMZ).

The Caddy VM will be configured to forward traffic for specific subdomains to the K3s cluster's Traefik Ingress Controller via the internal network VLAN (VLAN 30).

## Consequences

**Positive**

* **Hardened Security:** Caddy runs on Debian 13 (Trixie) in an isolated VM with a minimal attack surface, decoupled from the K3s cluster.
* **Simplicity:** One binary, one configuration file, and minimal dependencies make Caddy easy to manage and troubleshoot.
* **Cost Efficiency:** Caddy runs on a lightweight VM with minimal resource requirements; no additional physical hardware needed.

**Negative / trade offs**

* **Management overhead:** Adds another OS instance (Debian VM) to maintain, patch, and monitor alongside the K3s host.
* **Client IP preservation:** Traefik must be configured with `forwardedHeaders.trustedIPs` pointing to Caddy; otherwise, backend workloads only see Caddy's private IP in logs and access controls.
* **Host networking discipline:** The K3s host attaches to the DMZ VLAN via an unnumbered L2 bridge (no host IP address assigned), ensuring the host itself cannot be accessed from the DMZ.
* **Additional hop:** Slight latency overhead by proxying through Caddy before hitting Traefik.

## Alternatives considered

* **Using Traefik directly as public reverse proxy:** Rejected because exposing Traefik directly requires binding the K3s host or pods to public/DMZ interfaces, mingling external perimeter exposure with internal cluster infrastructure.
* **Running Caddy as a container on K3s:** Rejected because containers share the host Linux kernel, network stack, and storage subsystem. A container breakout could compromise the entire node. KVM provides full hardware virtualization and kernel isolation.
* **Running Caddy on OPNsense hardware:** Rejected because terminating public traffic directly on the firewall device introduces an unnecessary attack surface on the primary security perimeter.
