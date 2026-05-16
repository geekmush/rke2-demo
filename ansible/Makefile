# Ansible entry point for the do-nyc3-rke2-demo cluster.
#
# `make inventory` reads the current `tofu output -json` and rewrites
# inventory/generated.yaml. `make play` brings up the RKE2 cluster. Both
# require terraform to have been applied first.
#
# All targets assume PWD is ansible/.

TERRAFORM_DIR := ../terraform/environments/do-test
INVENTORY     := inventory/generated.yaml
PLAYBOOK      := playbooks/site.yml

.PHONY: help check-tools requirements inventory play play-check kubeconfig tunnel lint clean

help:
	@echo "Targets:"
	@echo "  requirements  -- install Ansible collections from requirements.yml"
	@echo "  inventory     -- regenerate $(INVENTORY) from `tofu output -json`"
	@echo "  play          -- run $(PLAYBOOK) (full RKE2 cluster bring-up)"
	@echo "  play-check    -- ansible-playbook --check --diff"
	@echo "  kubeconfig    -- print the export commands for the operator kubeconfig"
	@echo "  tunnel        -- start the autossh-based kube API tunnel (foreground)"
	@echo "  lint          -- ansible-lint roles/ playbooks/"
	@echo "  clean         -- remove generated inventory"

check-tools:
	@command -v ansible-playbook >/dev/null || { echo "ansible not on PATH"; exit 1; }
	@command -v tofu             >/dev/null || { echo "tofu not on PATH"; exit 1; }

requirements:
	ansible-galaxy collection install -r requirements.yml --upgrade

inventory: check-tools
	tofu -chdir=$(TERRAFORM_DIR) output -json | ./scripts/render-inventory.py > $(INVENTORY)
	@echo "wrote $(INVENTORY)"

play: check-tools inventory
	ansible-playbook $(PLAYBOOK)

play-check: check-tools inventory
	ansible-playbook --check --diff $(PLAYBOOK)

KUBECONFIG_PATH := $(HOME)/.kube/do-nyc3-rke2-demo

kubeconfig:
	@if [ -f $(KUBECONFIG_PATH) ]; then \
	  echo "# Run these in a shell that will use kubectl:"; \
	  echo "export KUBECONFIG=$(KUBECONFIG_PATH)"; \
	  echo "# In a SEPARATE terminal, start the SSH tunnel:"; \
	  echo "make -C $$(realpath .) tunnel"; \
	else \
	  echo "$(KUBECONFIG_PATH) not present yet -- run \`make play\` first"; \
	  exit 1; \
	fi

tunnel:
	./scripts/kube-tunnel.sh

lint:
	ansible-lint roles/ playbooks/

clean:
	rm -f $(INVENTORY)
