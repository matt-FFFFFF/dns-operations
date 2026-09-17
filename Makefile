SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

TF      ?= terraform
DNSCTL  ?= ./tools/dnsctl.py
POLICY_INPUT := build/policy-input.json
ZONES   := $(notdir $(patsubst %/,%,$(dir $(wildcard zones/*/zone.yaml))))

# One state file per zone, so every Terraform command names a zone. ZONE= picks
# one; without it these act on every zone in turn.
ZONE          ?=
TARGET_ZONES  := $(if $(ZONE),$(ZONE),$(ZONES))

# -reconfigure, because moving between zones changes the state key and
# Terraform would otherwise offer to migrate one zone's state into another's.
define tf_init
$(TF) -chdir=terraform init -input=false -reconfigure \
  -backend-config=backend/azurerm.hcl \
  -backend-config="key=zones/$(1).tfstate"
endef

.PHONY: help check validate policy test lint fmt fmt-check render render-diff \
        verify drift plan apply init clean test-fixtures changed-zones

help: ## Show this help
	@awk 'BEGIN{FS=":.*##"} /^[a-z][a-z-]*:.*##/ {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "  zones: $(ZONES)"

## --- what CI runs -------------------------------------------------------

check: fmt-check lint validate test test-fixtures test-changed-zones test-supersede policy ## Everything a pull request must pass
	@$(TF) -chdir=terraform init -backend=false -input=false >/dev/null
	@$(TF) -chdir=terraform validate
	@$(MAKE) --no-print-directory render-diff

validate: ## Parse and check the zones tree
	@$(DNSCTL) validate

$(POLICY_INPUT): $(shell find zones tools -type f 2>/dev/null) .github/CODEOWNERS | build
	@$(DNSCTL) build --out $@

policy: $(POLICY_INPUT) | build ## Evaluate policy/*.rego against the zones tree
	@if command -v conftest >/dev/null 2>&1; then \
	  conftest test --policy policy --all-namespaces $(POLICY_INPUT); \
	elif command -v opa >/dev/null 2>&1; then \
	  opa eval -d policy -i $(POLICY_INPUT) -f pretty 'data.dns.layout.warn[_]' \
	    | grep -v '^undefined$$' || true; \
	  if opa eval -d policy -i $(POLICY_INPUT) -f pretty \
	       --fail-defined 'data.dns.layout.deny[_]' > build/denials.txt 2>&1; \
	  then echo "policy: no denials"; else cat build/denials.txt; exit 1; fi; \
	else \
	  echo "policy: install conftest or opa -- brew install conftest"; exit 1; \
	fi

lint: ## Lint the workflows and the shell scripts
	@actionlint
	@shellcheck tools/*.sh tools/tests/*.sh
	@# Offline: every action is a full commit SHA. CI additionally runs
	@# --verify-comment, which needs a token to confirm each version comment
	@# names the version its SHA really is.
	@pinact run --fix=false --no-api

test: ## Run the policy unit tests
	@if command -v opa >/dev/null 2>&1; then opa test policy/; \
	elif command -v conftest >/dev/null 2>&1; then conftest verify --policy policy; \
	else echo "test: install opa or conftest -- brew install opa"; exit 1; fi

fmt: ## Format Terraform and Rego in place
	@$(TF) -chdir=terraform fmt -recursive
	@if command -v opa >/dev/null 2>&1; then opa fmt -w policy/; fi

fmt-check: ## Fail if anything is unformatted
	@$(TF) -chdir=terraform fmt -recursive -check -diff
	@if command -v opa >/dev/null 2>&1; then opa fmt --fail --diff policy/; fi

## --- looking at the tree ------------------------------------------------

render: ## Print every record the tree produces
	@$(DNSCTL) render

# tools/dnsctl.py and terraform/modules/records both turn the tree into records.
# Terraform is what applies; dnsctl is what validates and what compares against
# the live zone. They are allowed to be two implementations. They are not
# allowed to disagree.
render-diff: | build ## Check the two implementations of the layout still agree
	@for zone in $(ZONES); do \
	  $(TF) -chdir=terraform/modules/records init -backend=false -input=false >/dev/null; \
	  echo 'jsonencode(sort(keys(local.records)))' \
	    | $(TF) -chdir=terraform/modules/records console \
	        -var zone_name=$$zone -var zone_dir="$(CURDIR)/zones/$$zone" 2>/dev/null \
	    | tail -1 \
	    | python3 -c 'import sys,json; print("\n".join(json.loads(json.loads(sys.stdin.read()))))' \
	    > build/$$zone.terraform.keys; \
	  $(DNSCTL) render --keys --zone $$zone > build/$$zone.dnsctl.keys; \
	  if diff -u build/$$zone.terraform.keys build/$$zone.dnsctl.keys; then \
	    echo "render-diff: $$zone -- terraform and dnsctl agree ($$(wc -l < build/$$zone.dnsctl.keys | tr -d ' ') records)"; \
	  else \
	    echo "render-diff: $$zone -- terraform/modules/records and tools/dnsctl.py disagree"; exit 1; \
	  fi; \
	done

## --- reality ------------------------------------------------------------

verify: ## Ask the public DNS whether zone.yaml is still true
	@$(DNSCTL) verify

drift: ## Ask Cloudflare what it holds that this repository does not
	@$(DNSCTL) drift

## --- applying -----------------------------------------------------------

init: ## terraform init, for ZONE= or for each zone in turn
	@for zone in $(TARGET_ZONES); do \
	  echo "== $$zone"; $(call tf_init,$$zone); \
	done

plan: check ## Show what would change in Cloudflare
	@for zone in $(TARGET_ZONES); do \
	  echo "== $$zone"; $(call tf_init,$$zone) >/dev/null; \
	  $(TF) -chdir=terraform plan -input=false -var zone=$$zone -out=tfplan-$$zone; \
	done

apply: ## Apply the plan written by `make plan`
	@for zone in $(TARGET_ZONES); do \
	  echo "== $$zone"; $(call tf_init,$$zone) >/dev/null; \
	  $(TF) -chdir=terraform apply -input=false tfplan-$$zone; \
	done

clean: ## Remove generated files
	@rm -rf build tfplan terraform/tfplan-*

# Order-only prerequisite: anything that writes into build/ depends on the
# directory existing, but not on when it was last touched.
build:
	@mkdir -p build

## --- the checker's own tests --------------------------------------------

# Each fixture zone under tools/tests/zones breaks one thing on purpose.
FIXTURES := --zones tools/tests/zones --no-codeowners --today 2026-09-17

.PHONY: test-fixtures test-fixtures-update test-changed-zones test-supersede
test-fixtures: | build ## Check dnsctl still rejects what it is supposed to reject
	@$(DNSCTL) validate $(FIXTURES) > build/fixtures.txt 2>&1 || true
	@if diff -u tools/tests/expected.txt build/fixtures.txt; then \
	  echo "test-fixtures: $$(grep -c '^ERROR' tools/tests/expected.txt) rules still fire"; \
	else \
	  echo "test-fixtures: dnsctl's findings changed -- if that is intended, run 'make test-fixtures-update'"; \
	  exit 1; \
	fi

test-changed-zones: ## Check the matrix fan-out rules still hold
	@./tools/tests/changed-zones.sh

test-supersede: ## Check which waiting runs may be cancelled
	@./tools/tests/supersede-waiting.sh

changed-zones: ## Which zones would CI plan for the last commit?
	@./tools/changed-zones.sh --base HEAD~1

test-fixtures-update: ## Re-record the expected findings
	@$(DNSCTL) validate $(FIXTURES) > tools/tests/expected.txt 2>&1 || true
	@echo "test-fixtures-update: rewrote tools/tests/expected.txt"
