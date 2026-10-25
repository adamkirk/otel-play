SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# Load local overrides/secrets (HONEYCOMB_API_KEY etc.) if present.
-include .env
export

# ---- Config -----------------------------------------------------------------
CLUSTER_NAME   ?= otel-play
KUBE_CONTEXT   ?= k3d-$(CLUSTER_NAME)
OBS_NAMESPACE  ?= observability
APP_NAMESPACE  ?= shop

IMAGE_TAG      ?= dev
CATALOGUE_IMAGE ?= otel-play/catalogue-api:$(IMAGE_TAG)
ORDERS_IMAGE    ?= otel-play/orders-api:$(IMAGE_TAG)
WORKER_IMAGE    ?= otel-play/orders-worker:$(IMAGE_TAG)
WEB_IMAGE       ?= otel-play/web:$(IMAGE_TAG)

REQUIRED_TOOLS := docker k3d kubectl helm k6

KUBECTL := kubectl --context $(KUBE_CONTEXT)
HELM    := helm --kube-context $(KUBE_CONTEXT)

# ---- Meta -------------------------------------------------------------------
.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make \033[36m<target>\033[0m\n\nTargets:\n"} \
		/^[a-zA-Z0-9_%-]+:.*##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: check-deps
check-deps: ## Check required CLI tools are installed
	@missing=0; \
	for t in $(REQUIRED_TOOLS); do \
		if command -v $$t >/dev/null 2>&1; then \
			printf "  \033[32m✔\033[0m %s\n" $$t; \
		else \
			printf "  \033[31m✘\033[0m %s (brew install %s)\n" $$t $$t; missing=1; \
		fi; \
	done; \
	if ! docker info >/dev/null 2>&1; then \
		printf "  \033[31m✘\033[0m docker daemon not reachable\n"; missing=1; \
	fi; \
	if [ ! -f .env ]; then \
		printf "  \033[33m!\033[0m .env missing (cp .env.example .env)\n"; \
	fi; \
	exit $$missing

.PHONY: config
config: ## Print resolved configuration
	@echo "CLUSTER_NAME    = $(CLUSTER_NAME)"
	@echo "KUBE_CONTEXT    = $(KUBE_CONTEXT)"
	@echo "OBS_NAMESPACE   = $(OBS_NAMESPACE)"
	@echo "APP_NAMESPACE   = $(APP_NAMESPACE)"
	@echo "CATALOGUE_IMAGE = $(CATALOGUE_IMAGE)"
	@echo "ORDERS_IMAGE    = $(ORDERS_IMAGE)"
	@echo "WORKER_IMAGE    = $(WORKER_IMAGE)"
	@echo "WEB_IMAGE       = $(WEB_IMAGE)"
	@echo "HONEYCOMB_API_KEY set: $(if $(HONEYCOMB_API_KEY),yes,no)"
