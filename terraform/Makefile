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

.PHONY: help check-tools check-secrets check-tfvars init fmt fmt-check validate plan apply destroy output clean

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

init: check-tools
	$(TOFU) init -upgrade

fmt:
	tofu fmt -recursive .

fmt-check:
	tofu fmt -check -recursive .

# `validate` does not contact DO, but the DO provider still wants a token at
# plan/apply time. validate works after init even without secrets.
validate:
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
