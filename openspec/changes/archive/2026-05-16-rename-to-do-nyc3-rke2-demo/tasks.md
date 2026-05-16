# Tasks — rename-to-do-nyc3-rke2-demo

**Tracking issue:** [#20](https://github.com/geekmush/do-nyc3-rke2-demo/issues/20)

Implementation order. Suggested 3-commit PR split per task 14.

## Behavioral edits

- [x] 1. `variables.sh`: set `cluster_name=do-nyc3-rke2-demo` and `git_repo=do-nyc3-rke2-demo`.
- [x] 2. `terraform/environments/do-test/variables.tf`: `project_name` default `"do-nyc3-rke2-demo"`.
- [x] 3. `terraform/environments/do-test/terraform.tfvars.example`: comment showing `project_name` default updated.
- [x] 4. `ansible/inventory/group_vars/all/main.yml`: `cluster_name: do-nyc3-rke2-demo`.
- [x] 5. `apps/external-dns/values.yaml`: `txtOwnerId: do-nyc3-rke2-demo`.
- [x] 6. `ansible/scripts/render-inventory.py`: default `--key` argument `~/.ssh/do_nyc3_rke2_demo_ed25519`.
- [x] 7. `ansible/scripts/kube-tunnel.sh`: SSH key fallback `~/.ssh/do_nyc3_rke2_demo_ed25519`.

## Vendored upstream files (global rewrite)

- [x] 8. Run global `sed s/rke2-demo/do-nyc3-rke2-demo/g` across `apps/` and `variables.sh`, excluding `deploy.sh`. Same pattern as Phase 3a's `do-nyc3-rke2-demo -> rke2-demo` rewrite.
- [x] 9. Spot-check `apps/metallb-custom-resources/*.yaml` + `apps/nxrm-ha/values.yaml` show the new name.

## Documentation

- [x] 10. Bulk rewrite via `sed` across `docs/runbooks/`, `docs/diagrams/`, `README.md`, `CLAUDE.md`, `terraform/README.md` -- excluding `docs/upstream/` and `openspec/changes/archive/`.
- [x] 11. Sweep for places where the original name was contextually correct (e.g. issue references, "the cluster was called rke2-demo before" prose). Restore as needed.
- [x] 12. Add a note in `CLAUDE.md` documenting the naming convention so Phase 4 bare-metal picks something coherent (`bm-onprem-rke2-prod` or similar).

## Validation

- [x] 13. `tofu validate` clean (no behavioral changes that would break syntax, but sanity).
- [x] 14. Final sweep: `git grep '\brke2-demo\b'` -- any remaining hits should be in `openspec/changes/archive/`, `docs/upstream/`, `.claude/memory/`, or contextually-correct uses (e.g. this OpenSpec change's prose). No production-relevant occurrences.

## Close-out

- [x] 15. Open PR. Title: `Rename project identity to do-nyc3-rke2-demo (closes #20)`. Suggested commit split:
  - `feat: rename cluster identity to do-nyc3-rke2-demo` -- behavioral changes from tasks 1-7.
  - `chore(fluxcd-template): rewrite rke2-demo -> do-nyc3-rke2-demo in vendored files` -- task 8.
  - `docs: update CLAUDE.md, README, and runbooks for the new identity` -- tasks 10-12.
- [x] 16. Walk safe-staging checklist (nothing secret should be in scope; sanity check anyway).
- [x] 17. Merge.
- [x] 18. Archive: `git mv openspec/changes/rename-to-do-nyc3-rke2-demo openspec/changes/archive/<date>-rename-to-do-nyc3-rke2-demo`.
- [x] 19. Tomorrow's resume path uses the new identity from the start. No further rename work needed in Phase 3c / Longhorn etc.
