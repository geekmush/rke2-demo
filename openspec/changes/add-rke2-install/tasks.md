# Tasks — add-rke2-install

**Tracking issue:** [#6](https://github.com/geekmush/rke2-demo/issues/6)

Implementation order. Each numbered task is small enough to be a discrete commit.

## Tofu: load balancer + cp_endpoint output + ACL

- [x] 1. Pick the pinned RKE2 version from the current stable channel (https://github.com/rancher/rke2/releases). Record in `ansible/group_vars/all/main.yml` later.
- [x] 2. Add `kube_api_allowed_cidrs` variable to `terraform/modules/do-droplet-infra/variables.tf`:
  - Type: `list(object({ cidr = string, label = string }))`
  - **Required** (no default). Variable validation enforces at least one entry — DO interprets an empty LB allow list as "no firewall," the opposite of what we want.
  - DO rejects private/RFC1918 CIDRs (incl. the VPC CIDR) in LB firewalls — public CIDRs only. Document in the variable description.
- [x] 3. Mirror the variable in `terraform/environments/do-test/variables.tf` (also no default — env-level callers must supply) and thread it through `main.tf` to the module.
- [x] 4. Add `digitalocean_loadbalancer.cp` to `terraform/modules/do-droplet-infra/loadbalancer.tf`:
  - region from `var.region`, VPC-attached to `digitalocean_vpc.main.id`
  - 2 forwarding rules: tcp/6443->6443, tcp/9345->9345
  - health check: tcp on port 9345
  - target droplets: `digitalocean_droplet.cp[*].id`
  - size `lb-small`
  - `firewall { allow = [for e in var.kube_api_allowed_cidrs : "cidr:${e.cidr}"]; deny = [] }`
- [x] 5. Module output `cp_endpoint` exposing the LB IP (the regional DO LB doesn't expose a hostname attribute in this provider version; the IP is stable for the LB's lifetime).
- [x] 6. Update root env `terraform/environments/do-test/outputs.tf` to re-export `cp_endpoint`.
- [x] 7. Update `terraform/environments/do-test/terraform.tfvars.example` with a commented-out `kube_api_allowed_cidrs` block and the `curl -s https://api.ipify.org` one-liner for IP discovery.
- [x] 8. Operator populates `terraform/environments/do-test/terraform.tfvars` (gitignored) with at least one CIDR for their workstation. Verify entry shape.
- [x] 9. `make fmt`, `make validate`, `make plan` — plan should show **+1 LB** only, no droplet recreation.
- [x] 10. `make apply` to provision the LB. Verify:
  - LB IP populates in `make output` (`cp_endpoint`)
  - TCP/9345 health checks pass on all 3 CPs once RKE2 is installed (until then, LB UI shows 0/3 healthy — expected at this stage)
  - From the operator workstation: `nc -zv <cp_endpoint> 9345` opens the TCP connection (will be refused by the LB itself until backends are healthy, but the ACL allows your IP through)
  - From an IP not in `kube_api_allowed_cidrs`: TCP/6443 is blocked (sanity check, e.g. from a phone hotspot)

## Ansible scaffolding

- [x] 11. Directory layout: `ansible/{roles/{rke2_common,rke2_server,rke2_agent}/{tasks,templates,defaults,handlers,meta},playbooks,inventory,group_vars/all,scripts,artifacts}`.
- [x] 12. `ansible/.gitignore` excluding `artifacts/`, `inventory/generated.yaml`, `.galaxy-cache/`.
- [x] 13. `ansible/ansible.cfg`:
  - inventory path = `inventory/generated.yaml`
  - vars plugin: `community.sops.sops`
  - host key checking off (with comment: only for first apply; tighten when known_hosts pipeline lands)
  - retry files off
  - stdout callback: `yaml`
- [x] 14. `ansible/requirements.yml`: `community.sops` collection. Document install: `ansible-galaxy collection install -r requirements.yml`.
- [x] 15. `ansible/scripts/render-inventory.py` — zero-dep Python script:
  - `#!/usr/bin/env -S uv run --script`
  - reads `tofu output -json` from stdin OR a path arg
  - emits YAML to stdout with groups `rke2_servers`, `rke2_agents`, group_vars including `cp_endpoint` and `vpc_cidr`
  - host vars: `ansible_host` = public_ip, `private_ip`, `node_role`
- [x] 16. `ansible/Makefile`:
  - `inventory`  — calls render script with `tofu -chdir=... output -json`
  - `play`       — `ansible-playbook playbooks/site.yml`
  - `play-check` — `--check --diff`
  - `kubeconfig` — fetch + rewrite (or document `make play kubeconfig=true` flag)
  - `lint`       — `ansible-lint roles/ playbooks/`
  - `requirements` — `ansible-galaxy collection install -r requirements.yml`

## Secrets

- [x] 17. Generate `rke2_server_token` and `rke2_agent_token`: `openssl rand -hex 32`. Two separate values.
- [x] 18. Author `ansible/group_vars/all/secrets.enc.yaml` using the plaintext-outside-tree -> mv -> `sops --encrypt --in-place` pattern from `docs/runbooks/secrets.md`. Verify ENC blob.
- [x] 19. `ansible/group_vars/all/main.yml` — non-secret defaults: `rke2_version`, `rke2_disable: ['rke2-ingress-nginx']`, port numbers as plain ints if referenced.

## Roles

- [x] 20. `roles/rke2_common/tasks/main.yml` — replays cloud-init's work idempotently. Includes:
  - swap off (immediate + fstab check)
  - kernel modules loaded + `modules-load.d`
  - sysctls applied + `sysctl.d` drop-in
  - sshd_config.d drop-in for password/root login hardening
  - `changed=0` on a healthy host
- [x] 21. `roles/rke2_server/templates/config.yaml.j2` — Jinja templates over `rke2_server_token`, `rke2_agent_token`, `cp_endpoint`, `private_ip`, `tls_san_list`, `rke2_disable`. Includes `cluster-init` conditionally per the bootstrap-vs-join logic.
- [x] 22. `roles/rke2_server/tasks/main.yml`:
  - Write `/etc/rancher/rke2/config.yaml` (mode 0600, root:root) from the template.
  - Determine bootstrap-vs-join (probe `https://{{ cp_endpoint }}:9345/ping` — if any backend answers, this CP joins; else, the first inventory host inits).
  - Run install script with pinned `INSTALL_RKE2_VERSION` and `INSTALL_RKE2_TYPE=server`.
  - `systemctl enable --now rke2-server.service`.
  - Wait for `:9345/ping`, then `:6443/healthz` 200.
  - On `inventory_hostname == groups['rke2_servers'][0]`: fetch kubeconfig + rewrite server URL to `https://{{ cp_endpoint }}:6443` + write to `ansible/artifacts/kubeconfig` (mode 0600, on operator workstation).
- [x] 23. `roles/rke2_agent/templates/config.yaml.j2` — token, server URL, node-ip.
- [x] 24. `roles/rke2_agent/tasks/main.yml`:
  - Write config (mode 0600, root:root).
  - Run install script with `INSTALL_RKE2_TYPE=agent`.
  - `systemctl enable --now rke2-agent.service`.
- [x] 25. `playbooks/site.yml` orchestration:
  - Play 1: `hosts: all` -> `rke2_common`.
  - Play 2: `hosts: rke2_servers`, `serial: 1` (one CP at a time, bootstrap first) -> `rke2_server`.
  - Play 3: `hosts: rke2_agents` -> `rke2_agent`.

## Validation

- [x] 26. `make -C ansible requirements` clean.
- [ ] 27. `make -C ansible lint` clean (ansible-lint with default profile — relax noisy rules with `.ansible-lint` if needed).
- [x] 28. `make -C ansible inventory` produces a valid YAML inventory with the expected hosts and group_vars.
- [ ] 29. `make -C ansible play-check` clean (no errors during a `--check --diff` run; some `changed` items are expected on first play).
- [x] 30. `make -C ansible play` — full cluster bring-up. End state:
  - `kubectl get nodes` shows 3 CP Ready + 3 worker Ready.
  - All 3 etcd pods in `kube-system` Ready.
  - `kubectl get pods -A` — no `CrashLoopBackOff`.
- [x] 31. Second `make -C ansible play` reports **0 changed** tasks (idempotence).
- [ ] 32. Re-roll smoke: `tofu taint module.infra.digitalocean_droplet.cp[2]` -> `make -C terraform apply` -> `make -C ansible play --limit cp-03` -> node rejoins cleanly.

## Docs (groundrule #7)

- [x] 33. `docs/runbooks/rke2-install.md` — preconditions, prereqs, secrets setup, **`kube_api_allowed_cidrs` operator-IP setup** (including `curl -s https://api.ipify.org` discovery and the "edit `terraform.tfvars` then `make apply`" refresh when the IP changes), plan/apply/play flow, verification (`kubectl get nodes` from the operator workstation directly — no SSH tunnel), troubleshooting (LB unhealthy backends, cp-01 re-roll, "I'm locked out of kube API because my IP rotated"), tear-down.
- [x] 34. `docs/diagrams/rke2-topology.md` — Mermaid: LB -> 3 CPs, agents -> LB, etcd quorum, kubeconfig flow, operator path.
- [x] 35. Update top-level `README.md` "Getting started" to chain `do-bring-up` -> `rke2-install`.
- [ ] 36. Update `ansible/README.md` (if not auto-included by the scaffolding) pointing at the runbook.

## Close-out

- [ ] 37. Author PR — multiple commits per the project preference (`[[feedback_commit_style]]` memory). Suggested split:
  - `feat(terraform): add CP load balancer and cp_endpoint output`
  - `feat(ansible): scaffold layout, ansible.cfg, requirements, render-inventory`
  - `feat(ansible): add rke2_common role`
  - `feat(ansible): add rke2_server role + bootstrap-vs-join logic`
  - `feat(ansible): add rke2_agent role`
  - `feat(ansible): site.yml playbook orchestrating bring-up`
  - `feat(ansible): kubeconfig retrieval`
  - `docs: rke2 install runbook, topology diagram, README pointer`
- [ ] 38. Walk the secrets safe-staging checklist from `docs/runbooks/secrets.md`.
- [ ] 39. Open PR. Title: `Add RKE2 install via Ansible (closes #6)`. Include `kubectl get nodes` and `kubectl get pods -A` output (with cluster identifiers redacted) in the body.
- [ ] 40. Merge. Issue #6 closes automatically.
- [ ] 41. File follow-up issues:
  - "Copy etcd snapshots off-box to DO Spaces" (`type:task, phase-1, area:rke2, priority:normal`)
  - "Add ansible-lint to CI when CI lands" (`type:task, phase-1, area:ansible, priority:low`)
- [ ] 42. Archive change directory: `git mv openspec/changes/add-rke2-install openspec/changes/archive/<date>-add-rke2-install`.
