# ADR-0011: Deployment Model with Test Branches and Pinned Releases for Critical Components

* **Status:** Proposed
* **Date:** 2026-10-30

## Context

* `k8s/bootstrap/root-app.yaml` sets `targetRevision: HEAD`. Every cluster follows `main`, so every push reaches production as soon as ArgoCD syncs.
* ADR-0010 assigns update rehearsals to AWS. AWS therefore has to run a state that production does not run yet.
* The root Application is not managed by ArgoCD. It is applied by the `k3s_install` role ("Apply ArgoCD Root Application") and changes only when the playbook runs.
* After RemoteLab access ends, regressions in MetalLB L2, VLAN trunking and the Caddy → Traefik path can no longer be tested before production (ADR-0010). Production must be easy to roll back without a new commit and without touching K3s.
* ADR-0006 Track 1 deploys application updates continuously from `main` and rolls them back with `git revert`. With 30+ applications and Renovate, a manual release for every update would not be sustainable, so this has to stay possible for most applications.

## Decision

### 1. Environments are directories, changes are branches

* Every change is made on a test branch (`test/<topic>`) and validated on AWS before it is merged into `main`.
* Environment differences stay in `ansible/inventory/<env>/` and `k8s/clusters/<env>/` (ADR-0010). There is no long-lived branch per environment.

### 2. Two release tracks: pinned and tracking

Every component belongs to exactly one track:

| Track | Production follows | Criteria | Examples |
| :--- | :--- | :--- | :--- |
| **Pinned** | A fixed commit SHA on `main` | **Platform:** a failure affects all services. **Network-critical:** a failure affects the home network beyond the cluster. **Stateful with migrations:** a failure cannot be undone by `git revert`. | MetalLB, Traefik, Pi-hole, Omada Controller, Nextcloud, Paperless-ngx |
| **Tracking** | `main` | Everything else. | Jellyfin, stateless tools |

* The track is expressed by location in the repository, not by labels: one directory per track, each rendered by its own ApplicationSet. A change of track shows up as a rename in the Git history. The exact layout is defined together with the application structure.
* Platform components under `k8s/components/` are always pinned.
* On AWS, both tracks follow the test branch. The revision of each ApplicationSet is set per cluster overlay.
* Tracking applications may only rely on platform features that are already part of the current production release.

### 3. Production pins are full commit SHAs on `main`

* The pinned revision is an inventory variable, `argocd_target_revision`. `root-app.yaml` becomes a template in the `k3s_install` role.
  * AWS: the test branch name.
  * Production: a full 40-character commit SHA. A comment names the release, e.g. its tag.

  ```yaml
  # ansible/inventory/production/group_vars/all.yaml
  # Release 2026-11-14: MetalLB 0.15 (tag release-2026-11-14)
  argocd_target_revision: "<full 40-character SHA>"
  ```

* The SHA is binding, the comment is a label. Before a release or rollback, they are checked against each other (`git rev-parse <tag>^{commit}`).
* Only commits reachable from `main` are released.

### 4. Tested commit and released commit are identical

* Test branches are merged into `main` by fast-forward only (`git merge --ff-only`). No new commit is created, so the SHA tested on AWS is the SHA released to production, and commit signatures are kept.
* If `main` has moved since the test branch was branched off or last rebased, the fast-forward fails. The branch is rebased onto `main` and tested on AWS again.
* GitHub's "Squash and merge" and "Rebase and merge" are not used, because both create new commits.

### 5. `main` is protected on GitHub

A ruleset on `main` enforces the model on the server:

| Rule | Purpose |
| :--- | :--- |
| Require linear history | No merge commits on `main`. |
| Block force pushes | Released SHAs cannot disappear from `main`. |
| Restrict deletions | `main` cannot be deleted. |
| Require signed commits | Every commit on `main` is signed. |

The bypass list stays empty. "Require a pull request before merging" is **not** enabled, because a fast-forward from the command line is a direct push.

### 6. Release and rollback

* **Pinned track:**
  * A production run of the playbook updates K3s first and then switches ArgoCD to the new revision.
  * Before a release that updates a stateful application, a backup or snapshot of its data is taken.
  * The tasks that apply the root Application (including the wait for the Application CRD) carry the tag `argocd_root_app`.
  * Rollback: set `argocd_target_revision` to the previous release SHA and run only these tasks over SSH:

    ```bash
    ansible-playbook -i inventory/production site.yaml --tags argocd_root_app
    ```

    No commit is reverted, and K3s is not touched. Ingress is not required, because ArgoCD fetches from Git outbound.
* **Tracking track:** Updates reach production when they are merged into `main`. Rollback is `git revert` (ADR-0006 Track 1).

### 7. Moving an application between tracks is a migration

The two ApplicationSets see different revisions. After a move from tracking to pinned is pushed, the tracking ApplicationSet no longer generates the application, while the pinned one does not generate it until the next release. By default, the Application is deleted in between, and with the resources finalizer its resources, including PVCs, are deleted with it. A move in the other direction leaves two Applications managing the same resources until the next release.

* Stateful applications use the StorageClass `local-path-retain` (`reclaimPolicy: Retain`, see ADR-0009), so their data survives any deletion path above the storage layer.
* Every move between tracks is planned as a migration with a backup.

## Consequences

**Positive:**
* Platform, network-critical and stateful components reach production only with an explicit release.
* Production runs exactly the commit that was tested on AWS.
* Rollback of the pinned track needs no `git revert` under pressure and works while ingress is down.
* Most applications keep the low-effort update path of ADR-0006 Track 1.
* `main` holds only tested, linear, signed history.

**Negative & Trade-offs:**
* **Every release is a manual step:** fast-forward, update the SHA in the inventory, take backups where needed, run the playbook.
* **ADR-0006 Track 1 is amended.** Continuous deployment from `main` applies only to the tracking track. Renovate updates for pinned components, including auto-merged patches, reach production only with the next release.
* **Version skew between tracks.** Tracking applications run newer manifests than the pinned platform. A tracking application that relies on an unreleased platform feature breaks.
* **Moving an application between tracks can delete it** (see Decision 7).
* **SHA and comment can drift apart.** The SHA is the source of truth. A wrong comment does no harm, but it can mislead during a rollback.
* **Rollback depends on SSH and the control node.** If either is unavailable, production cannot be switched.
* **Admin rules are not in Git.** The GitHub ruleset is configured in the repository settings and documented here only.
* **Branch protection for private repositories requires GitHub Pro.**
* **Open questions:** Whether Applications carry the resources finalizer, and whether the ApplicationSets use `preserveResourcesOnDeletion` or `applicationsSync: create-update`, must be decided before the first ApplicationSet is deployed.

## Alternatives Considered

* **Production follows `main` for everything:**
  * *Rejected:* Every push reaches production, including platform changes that can take down ingress for all services.
* **All applications pinned:**
  * *Rejected:* With 30+ applications and Renovate, every update would need a manual release. Updates would either pile up or be released without review.
* **One branch per environment:**
  * *Rejected in ADR-0010:* Branches drift apart, and it is unclear which state is the reference.
* **Track selected by labels instead of directories:**
  * *Rejected:* A label change is a single line inside a manifest. A directory move is visible in the file structure and as a rename in the Git history.
* **Production pinned to a tag:**
  * *Rejected:* Tags can be moved or deleted, so a rollback target could change unnoticed. Tags remain useful as labels.
* **Squash or rebase merges via GitHub:**
  * *Rejected:* They create new commits, so the released SHA was never tested as such.
* **Root Application managed by ArgoCD (app-of-apps for the root itself):**
  * *Rejected for now:* Switching revisions would then need a commit, and a broken sync could block its own rollback.
