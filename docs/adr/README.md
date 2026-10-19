# Architecture Decision Records

This folder documents significant architecture decisions of this project:
**what** was decided, **why**, and which **consequences** were accepted.

> [!NOTE]
> ADRs were adopted starting in Phase 3 of this project. Earlier foundational decisions (such as using K3s or Debian 13) are documented in the main documentation and may be added retroactively if key architectural changes occur.

## Rules

* One decision per file, numbered: `NNNN-short-title.md`.
* Records are never deleted. A reversed decision is replaced by a new ADR, and
  the old one gets the status `Superseded by ADR-XXXX`.
* Keep them short (about one page).

## Statuses

New ADRs typically start as `Proposed` or `Accepted`:

* `Proposed`: Planned for an upcoming phase (design accepted, not yet implemented in code).
* `Accepted`: Decided and active in the codebase.
* `Superseded by ADR-XXXX`: Replaced by a newer decision.
* `Deprecated`: No longer valid, without a successor.

## Index

| ADR | Title | Status |
| :--- | :--- | :--- |
| [0001](0001-ip-address-plan.md) | IP Address Plan (Dual-Stack) | Accepted |
| [0002](0002-remotelab-ansible-control-node.md) | RemoteLab Ansible Control Node (Dedicated VM vs. WSL 2) | Accepted |
| [0003](0003-caddy-instance-in-vm-as-reverse-proxy.md) | Caddy Instance in VM as Reverse Proxy | Proposed |
| [0004](0004-separation-day-1-provisioning-and-os-patch-management.md) | Separation between Day-1 Provisioning and OS Patch Management | Accepted |
| [0005](0005-loose-mode-rp-filter-for-cni-compatibility.md) | Loose-Mode Reverse Path Filtering (rp_filter) for Kubernetes CNI Compatibility | Accepted |
| [0006](0006-dual-track-update-and-lifecycle-strategy.md) | Dual-Track Update and Lifecycle Strategy | Accepted |
| [0007](0007-tls-sans-for-remote-kubernetes-api-access.md) | Declarative TLS Subject Alternative Names (SANs) for Remote Kubernetes API Access | Accepted |
| [0008](0008-bare-metal-bulk-storage-mergerfs-and-snapraid.md) | Bulk Storage Architecture via mergerfs and SnapRAID on Bare Metal | Accepted |


## Template

```markdown
# ADR-NNNN: Title

* **Status:** Accepted
* **Date:** YYYY-MM-DD

## Context
What problem or constraint forces a decision?

## Decision
What did we decide?

## Consequences
Positive and negative effects we accept.

## Alternatives considered
Options that were rejected, and why.
```
