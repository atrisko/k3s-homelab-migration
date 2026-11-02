# Issues

This folder tracks defects and known issues found during testing: **what** was observed, **how** it was measured, and **what** was decided.

## Rules

* One issue per file, numbered: `NNNN-short-title.md`.
* Files are never moved or deleted, so references from the test catalog, the roadmap and run records stay valid.
* The status is kept in the file header and in the table below. Both are updated together.

## Statuses

* `Open`: Not resolved. An open issue may be accepted as a known issue; the file then states the conditions for re-evaluation.
* `Resolved`: Fixed and verified in a documented run. The file names the fixing commit and the run. An issue that occurs intermittently defines its own verification criterion (e.g. a number of consecutive clean boots), because a single passing run does not prove a fix.
* `Won't fix`: Closed without a fix. The file states why.

## Index

| No. | Title | Status |
| --- | --- | --- |
| [0001](0001-k3s-boot-crash-netlink.md) | K3s exits once after boot: network policy controller fails to list links | Open (accepted as known issue) |
