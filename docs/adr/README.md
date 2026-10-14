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

New ADRs start as `Accepted`. Later they may become:

* `Superseded by ADR-XXXX`: replaced by a newer decision.
* `Deprecated`: no longer valid, without a successor.

## Index

| ADR | Title | Status |
| :--- | :--- | :--- |
| [0001](0001-ip-address-plan.md) | IP Address Plan (Dual-Stack) | Accepted |
| [0002](0002-remotelab-ansible-control-node.md) | RemoteLab Ansible Control Node (Dedicated VM vs. WSL 2) | Accepted |
| [0003](0003-caddy-instance-in-vm-as-reverse-proxy.md) | Caddy Instance in VM as Reverse Proxy | Accepted |

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
