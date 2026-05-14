# OpenTofu wrapper for rke2-demo.
#
# Targets that need the DigitalOcean API token decrypt secrets.enc.tfvars on
# the fly into a temp file, point Tofu at it, and remove the temp file on exit
# (success OR failure). Plaintext token never lingers in the working tree and
# never enters shell history.
#
# Usage:
#   make plan        # init (if needed) + plan
#   make apply       # apply (with confirmation)
#   make destroy     # destroy (with confirmation)
#   make output      # show outputs
#   make fmt         # tofu fmt -recursive (rewrites)
#   make fmt-check   # tofu fmt -check -recursive (CI-style, no rewrite)
#   make validate    # tofu validate
#   make init        # tofu init -upgrade

ENV_DIR    := environments/do-test
SECRETS    := $(ENV_DIR)/secrets.enc.tfvars
TFVARS_EX  := $(ENV_DIR)/terraform.tfvars.example
TFVARS     := $(ENV_DIR)/terraform.tfvars

# Decrypted token tfvars is written to a temp file and removed on shell exit
# via `trap`. We resolve mktemp once per recipe so a single recipe sees one
# consistent path.
TOFU       := tofu -chdir=$(ENV_DIR)

CLOUDINIT_TPL := modules/do-droplet-infra/cloud-init.yaml.tftpl

.PHONY: help check-tools check-secrets check-tfvars cloud-init-ascii-check init fmt fmt-check validate plan apply destroy output clean

help:
	@echo "Targets: init, fmt, fmt-check, validate, plan, apply, destroy, output, clean"
	@echo "plan/apply/destroy require: sops keyring present, $(SECRETS) populated, $(TFVARS) created from .example"

check-tools:
	@command -v tofu >/dev/null || { echo "tofu not on PATH"; exit 1; }

check-secrets:
	@command -v sops >/dev/null || { echo "sops not on PATH"; exit 1; }
	@test -f $(SECRETS) || { echo "Missing $(SECRETS). Create it per docs/runbooks/do-bring-up.md."; exit 1; }

check-tfvars:
	@test -f $(TFVARS) || { \
	  echo "Missing $(TFVARS). Copy $(TFVARS_EX) and edit ssh_pubkey:"; \
	  echo "  cp $(TFVARS_EX) $(TFVARS)"; \
	  exit 1; \
	}

# Catch non-ASCII bytes in cloud-init templates BEFORE `tofu apply`. cloud-init's
# embedded PyYAML rejects characters like em-dashes (U+2014) and silently drops
# the entire user-data document, leading to droplets with cloud-config that
# never ran. See issue #4 for the failure mode.
cloud-init-ascii-check:
	@if LC_ALL=C grep -nP '[^\x00-\x7F]' $(CLOUDINIT_TPL); then \
	  echo "ERROR: non-ASCII bytes found in $(CLOUDINIT_TPL) (lines above)."; \
	  echo "cloud-init's PyYAML will reject the user-data and silently no-op write_files/runcmd."; \
	  echo "Replace with ASCII equivalents (e.g. em-dash -> '--')."; \
	  exit 1; \
	fi

init: check-tools
	$(TOFU) init -upgrade

fmt:
	tofu fmt -recursive .

fmt-check:
	tofu fmt -check -recursive .

# `validate` does not contact DO, but the DO provider still wants a token at
# plan/apply time. validate works after init even without secrets.
validate: cloud-init-ascii-check
	$(TOFU) validate

plan: check-tools check-secrets check-tfvars
	@tmp=$$(mktemp --suffix=.tfvars); \
	trap 'rm -f "$$tmp"' EXIT; \
	sops --decrypt $(SECRETS) > "$$tmp"; \
	$(TOFU) plan -var-file="$$(realpath "$$tmp")" -out=tfplan.bin

apply: check-tools check-secrets check-tfvars
	@tmp=$$(mktemp --suffix=.tfvars); \
	trap 'rm -f "$$tmp"' EXIT; \
	sops --decrypt $(SECRETS) > "$$tmp"; \
	$(TOFU) apply -var-file="$$(realpath "$$tmp")"

destroy: check-tools check-secrets check-tfvars
	@tmp=$$(mktemp --suffix=.tfvars); \
	trap 'rm -f "$$tmp"' EXIT; \
	sops --decrypt $(SECRETS) > "$$tmp"; \
	$(TOFU) destroy -var-file="$$(realpath "$$tmp")"

output:
	$(TOFU) output

# Wipe local plan artifacts. Does NOT touch state.
clean:
	rm -f $(ENV_DIR)/tfplan.bin
