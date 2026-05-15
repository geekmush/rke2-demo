# Tasks — add-fluxcd-template-vendor

**Tracking issue:** [#14](https://github.com/geekmush/rke2-demo/issues/14)

Implementation order. Each numbered task is a discrete-commit-sized chunk; suggested commit subjects in task 30.

## Vendoring

- [ ] 1. Add the `fluxcd-template` git remote pointing at `https://github.com/devopscoop/fluxcd-template.git`.
- [ ] 2. `git fetch fluxcd-template main`.
- [ ] 3. `git merge --allow-unrelated-histories --no-commit fluxcd-template/main`.
- [ ] 4. Resolve `.sops.yaml` collision: union of rules, single (our) age recipient, widened `secrets.yaml` rule's `encrypted_regex` to include our token-matching pattern.
- [ ] 5. Resolve `.gitignore` collision: union (adds `bin/*` and `*.decrypted`).
- [ ] 6. Replace `CODEOWNERS` with `* @geekmush`.
- [ ] 7. Move template's `README.md` to `docs/upstream/fluxcd-template-README.md`; restore ours.
- [ ] 8. `git add -A && git commit` the merge.

## Adapt to repo conventions

- [ ] 9. Global rewrite `project1-dev` -> `rke2-demo` across `apps/`, `flux/`, and `variables.sh`. Do NOT touch `deploy.sh`. Commit.
- [ ] 10. Edit `variables.sh` settings: `cluster_name=rke2-demo`, `git_platform=github`, `git_owner=geekmush`, `git_repo=rke2-demo`, `k8s_platform=rke2`. Commit.
- [ ] 11. Add `rke2)` case to `deploy.sh`'s `k8s_platform` switch: `additional_apps=(longhorn)`. Verify the script's tail loop concatenates correctly. Commit.

## DNS provider swap (Cloudflare -> DigitalOcean)

- [ ] 12. `apps/external-dns/values.yaml`: replace `provider:` block + `env` block per design.md. Confirm against `helm show values external-dns/external-dns --version 1.20.0` whether `provider: digitalocean` is top-level string or nested object on this chart version; adjust if needed.
- [ ] 13. `apps/cert-manager-custom-resources/clusterissuer.yaml`: uncomment the DNS-01 solver and point it at DigitalOcean per design.md.
- [ ] 14. Create plaintext `apps/external-dns/secrets.yaml.decrypted` with the K8s Secret spec carrying the DO API token; SOPS-encrypt to `apps/external-dns/secrets.yaml`; remove the `.decrypted` file. Verify ENC blob.
- [ ] 15. Same for `apps/cert-manager-custom-resources/digitalocean-dns.secrets.yaml` (namespace: cert-manager).
- [ ] 16. Update `apps/external-dns/kustomization.yaml` to reference `secrets.yaml` if not already present.
- [ ] 17. Update `apps/cert-manager-custom-resources/kustomization.yaml` resource list: remove `cloudflare-apikey-secret.secrets.yaml`, add `digitalocean-dns.secrets.yaml`.
- [ ] 18. Delete the now-orphaned `apps/cert-manager-custom-resources/cloudflare-apikey-secret.secrets.yaml.decrypted` if present.
- [ ] 19. Set `enableGatewayAPI: false` in `apps/cert-manager/values.yaml`. Commit DNS-swap tasks (12-19) as one commit.

## Existing SOPS file retrofit

- [ ] 20. Rename `ansible/inventory/group_vars/all/secrets.enc.yaml` -> `ansible/inventory/group_vars/all/secrets.yaml`. Verify file still decrypts with the operator age key.
- [ ] 21. Update `ansible/ansible.cfg`: broaden `valid_extensions` to `.yaml,.yml,.json`; add `handle_unencrypted_files = skip`. Commit (20+21).

## Ansible cluster_name variable

- [ ] 22. Add `cluster_name: rke2-demo` to `ansible/inventory/group_vars/all/main.yml`.
- [ ] 23. Refactor `operator_kubeconfig_path` to use `{{ cluster_name }}`.
- [ ] 24. Run `make -C ansible play` to verify idempotence (expect `changed=2` on cp-01 from kubeconfig rewrite if the path differs at all; otherwise `changed=0`). Commit (22+23).

## Documentation

- [ ] 25. Update `CLAUDE.md` file-layout section + new "FluxCD vendor pattern" section.
- [ ] 26. Update `README.md` as needed (phase-3 references, etc.). Commit (25+26).

## Validation

- [ ] 27. `kustomize build` clean over `apps/*/` and `flux/flux-system/`. (Note: some apps reference resources that don't exist until deploy.sh runs -- kustomize-build clean is for the static-resource subset; will document any acceptable warnings.)
- [ ] 28. SOPS round-trip: `git ls-files '*.secrets.yaml' '*.helm_secrets.yaml' '*.enc.*' | while read f; do sops -d "$f" >/dev/null && echo "OK $f" || echo "FAIL $f"; done`.
- [ ] 29. `tofu validate` passes; `make -C ansible play` idempotent end-to-end.

## Close-out

- [ ] 30. Open PR. Title: `Phase 3a: vendor devopscoop/fluxcd-template + adapt for rke2-demo (closes #14)`. Suggested commit split:
  - `docs(openspec): propose add-fluxcd-template-vendor`
  - `chore: vendor devopscoop/fluxcd-template via merge`
  - `chore(fluxcd-template): pre-rewrite project1-dev -> rke2-demo`
  - `feat(fluxcd-template): set variables.sh for rke2-demo + rke2 platform`
  - `feat(fluxcd-template): add rke2 platform case to deploy.sh`
  - `feat(fluxcd-template): swap Cloudflare -> DigitalOcean DNS (external-dns + cert-manager)`
  - `chore(sops): retrofit ansible secrets to secrets.yaml convention`
  - `feat(ansible): introduce cluster_name var`
  - `docs(claude-md): document FluxCD vendor pattern`
- [ ] 31. Walk the secrets safe-staging checklist from `docs/runbooks/secrets.md`.
- [ ] 32. Merge. Issue #14 closes automatically.
- [ ] 33. Archive: `git mv openspec/changes/add-fluxcd-template-vendor openspec/changes/archive/<date>-add-fluxcd-template-vendor`.
