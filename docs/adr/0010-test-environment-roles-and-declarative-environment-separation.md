# ADR-0010: Test Environment Roles and Declarative Environment Separation

* **Status:** Proposed
* **Date:** 2026-10-28

## Context

The project runs on three environments, and their purposes have changed:

* **AWS PoC (Phase 1):** Originally a Terraform exercise. It is now meant to be a full-stack staging environment: the complete setup with all 30+ services running, used before major updates.
* **RemoteLab (Phase 4.5, ADR-0002):** A Hyper-V VM on a 16 GB host. It is available around the clock for now, but access ends in about a year. After leaving memory for the host and the control node, it cannot run the full workload set. It does sit in a real L2/L3 network with an IPv4 router and LAN clients. The network has no IPv6 router (no router advertisements, verified 2026-10-30), so SLAAC and global IPv6 addresses cannot be tested there.
* **Bare Metal (Phase 5+):** The production target. Tests here put the platform and, later, the migrated data at risk.

The environments differ in capabilities, not just in sizing:

* **MetalLB L2 mode does not work in an AWS VPC.** MetalLB announces LoadBalancer IPs via ARP/NDP. In a VPC, ARP is answered by the VPC fabric based on the IPs assigned to an ENI, and the source/destination check drops traffic to unassigned IPs. Traefik's LoadBalancer IP would be allocated but unreachable, which would take down ingress for all services at once.
* VLAN trunking, the KVM-based Caddy DMZ VM (ADR-0003) and the Intel iGPU are not available on AWS.
* Some services (Pi-hole, Omada Controller) can start on AWS, but their actual function (LAN DNS, device discovery) cannot be tested there.

The repository does not separate environments yet:

* All inventories share `ansible/inventory/group_vars/`, so group variables apply to every environment.
* `k8s/bootstrap/root-app.yaml` points to one fixed path for every cluster.

Without a clear separation, environment differences would end up as conditionals scattered across roles and manifests.

## Decision

### 1. Each environment has a defined test role

| Environment | Tests |
| :--- | :--- |
| **AWS** | Full workload set, update rehearsals (K3s, ArgoCD, application images), restore from backup, complete rebuild from scratch (`terraform destroy` → apply → playbook) |
| **RemoteLab** | Real network and platform behaviour: MetalLB L2, dual-stack with static ULA, Caddy → Traefik header propagation, reboot and detached-storage behaviour, idempotency |
| **Bare Metal** | Acceptance: tests that already passed in the environment responsible for them. In addition, SLAAC and global IPv6 addresses, which no other environment can test |

Every test case names the environment responsible for it. A milestone is passed when all its test cases have passed in their environment.

### 2. The environment is declared, never detected

* The environment is selected only by the inventory passed with `-i`. Roles never detect it at runtime (no IMDS, hostname or interface heuristics).
* Each environment gets its own inventory directory with its own `group_vars/`:
  `ansible/inventory/{aws,remotelab,production}/`.
* Each inventory sets a `cluster_name` variable (`aws`, `remotelab`, `baremetal`).
* Roles contain no conditionals on environment names. Differences are expressed as variables named after the capability, with defaults in the role (e.g. `k3s_disable: [servicelb]` instead of `is_aws: true`).

### 3. GitOps uses a Kustomize base with per-cluster overlays

```text
k8s/
├── base/                 # shared manifests (Traefik config, applications)
├── components/           # optional building blocks (e.g. metallb/)
└── clusters/
    ├── aws/              # base, no MetalLB, Traefik exposed via K3s ServiceLB
    ├── remotelab/        # base + metallb + test pool
    └── baremetal/        # base + metallb + VLAN 30 pool (ADR-0001)
```

* The `k3s_install` role renders the root Application from a template with `path: k8s/clusters/{{ cluster_name }}`. The environment flows from inventory to root Application to ArgoCD without detection at any step.
* Overlays contain only differences. Anything identical in all clusters belongs in `base/`.

## Consequences

**Positive:**

* Full-stack tests no longer depend on RemoteLab's RAM limit or its remaining lifetime.
* Roles and base manifests stay environment-agnostic. Adding an environment means adding an inventory directory and an overlay, not touching roles.
* Environment differences are visible in one place per layer (`inventory/<env>/`, `k8s/clusters/<env>/`) and can be reviewed as such.
* Test results can be tied to an environment with a known capability set.

**Negative & Trade-offs:**

* **SLAAC is tested only on bare metal.** Neither AWS nor the RemoteLab offers IPv6 router advertisements. Settings that affect SLAAC (e.g. `accept_ra`) can be checked everywhere, but their effect is first observable at bare-metal acceptance.
* **AWS never matches the production ingress path.** AWS uses ServiceLB instead of MetalLB and has no Caddy DMZ VM. The ingress path is validated only in RemoteLab.
* **No successor for RemoteLab's tests.** Once RemoteLab access ends, AWS takes over the tests before updates, but MetalLB L2, VLAN trunking, dual-stack/SLAAC and the Caddy → Traefik path cannot be tested there. A regression in these components then shows up in production first and can take down ingress for all services. This is accepted for an outage of up to one day:
  * Production follows a fixed release state and can be rolled back by a targeted playbook run over SSH, without a new commit and without touching K3s ([ADR-0011](0011-deployment-model.md)).
  * A second Pi-hole instance on a separate system keeps LAN DNS available while the server is down.
* **Higher AWS cost.** The full workload set needs a much larger instance than the current `t3.small`. The optional AWS Budget Alert (Phase 1) becomes mandatory.
* **Test data is an open question.** Meaningful update and restore tests need realistic data. Which data may be stored in AWS (photos and documents are excluded by default) must be decided before the first restore test.
* **Restructuring work.**
  * Inventories move into per-environment directories. `ansible.cfg` (default inventory) and the Terraform inventory generator (`local_file.ansible_inventory`) must point to the new paths.
  * `k8s/test-workload/` is replaced by the base/overlay layout.
  * `root-app.yaml` becomes a template.
* **Overlay drift risk.** Overlays can grow into hidden forks. Mitigation: keep patches minimal and review overlays when the base changes.
* **New tooling to learn:** Kustomize (built into `kubectl` and ArgoCD).

## Alternatives Considered

* **Runtime environment detection in roles (`when: env == 'aws'`):**
  * *Rejected:* Detection relies on heuristics that can break (cf. Review 2 R2-5), spreads environment logic across all roles and multiplies the code paths that need testing.
* **One Git branch per environment:**
  * *Rejected:* Branches drift apart, changes must be merged in several directions, and it is unclear which state is the reference.
* **Full manifest copies per environment:**
  * *Rejected:* Most of the content is identical, so every change would have to be made several times.
* **Helm umbrella chart with values per environment:**
  * *Considered:* Works, but adds a templating layer for manifests that are otherwise plain YAML. Kustomize is supported natively by ArgoCD and produces plain YAML.
* **AWS-native load balancing (AWS Load Balancer Controller / NLB) on AWS:**
  * *Rejected for now:* Adds AWS-specific components and costs that exist only in staging. K3s ServiceLB is already part of K3s and enough to make Traefik reachable.
* **Running the full workload set in RemoteLab:**
  * *Rejected:* Not possible within 16 GB host RAM, and the environment will no longer be available in about a year.
