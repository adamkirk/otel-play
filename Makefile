SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# Load local overrides/secrets (HONEYCOMB_API_KEY etc.) if present.
-include .env
export

# ---- Config -----------------------------------------------------------------
CLUSTER_NAME   ?= otel-play
KUBE_CONTEXT   ?= k3d-$(CLUSTER_NAME)
K3D_CONFIG     ?= deploy/k3d/cluster.yaml
HTTP_PORT      ?= 80
OBS_NAMESPACE  ?= observability
APP_NAMESPACE  ?= shop

IMAGE_TAG      ?= dev
CATALOGUE_IMAGE ?= otel-play/catalogue-api:$(IMAGE_TAG)
# Also runs the queue worker, with a different command.
ORDERS_IMAGE    ?= otel-play/orders-api:$(IMAGE_TAG)
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
	@echo "HTTP_PORT       = $(HTTP_PORT)"
	@echo "OBS_NAMESPACE   = $(OBS_NAMESPACE)"
	@echo "APP_NAMESPACE   = $(APP_NAMESPACE)"
	@echo "CATALOGUE_IMAGE = $(CATALOGUE_IMAGE)"
	@echo "ORDERS_IMAGE    = $(ORDERS_IMAGE)"
	@echo "WEB_IMAGE       = $(WEB_IMAGE)"
	@echo "HONEYCOMB_API_KEY set: $(if $(HONEYCOMB_API_KEY),yes,no)"

# ---- Cluster ----------------------------------------------------------------
.PHONY: cluster-up
cluster-up: ## Create the k3d cluster (idempotent) and namespaces
	@if k3d cluster get $(CLUSTER_NAME) >/dev/null 2>&1; then \
		echo "Cluster $(CLUSTER_NAME) already exists"; \
	else \
		k3d cluster create $(CLUSTER_NAME) --config $(K3D_CONFIG) \
			--port "$(HTTP_PORT):80@loadbalancer"; \
	fi
	@$(MAKE) --no-print-directory namespaces

.PHONY: cluster-down
cluster-down: ## Delete the k3d cluster
	k3d cluster delete $(CLUSTER_NAME)

.PHONY: namespaces
namespaces: ## Create the observability and app namespaces
	@for ns in $(OBS_NAMESPACE) $(APP_NAMESPACE); do \
		$(KUBECTL) create namespace $$ns --dry-run=client -o yaml | $(KUBECTL) apply -f -; \
	done

.PHONY: cluster-status
cluster-status: ## Show nodes, namespaces and Traefik status
	$(KUBECTL) get nodes -o wide
	$(KUBECTL) get namespaces
	$(KUBECTL) -n kube-system get deploy traefik

# ---- catalogue-api ------------------------------------------------------------
.PHONY: build-catalogue
build-catalogue: ## Build the catalogue-api image
	docker build -t $(CATALOGUE_IMAGE) catalogue-api

.PHONY: import-catalogue
import-catalogue: ## Import the catalogue-api image into k3d
	k3d image import -c $(CLUSTER_NAME) $(CATALOGUE_IMAGE)

.PHONY: deploy-catalogue
deploy-catalogue: ## Install/upgrade the catalogue-api chart
	$(HELM) upgrade --install catalogue-api deploy/charts/catalogue-api \
		--namespace $(APP_NAMESPACE) \
		--set image.repository=$(firstword $(subst :, ,$(CATALOGUE_IMAGE))) \
		--set image.tag=$(IMAGE_TAG) \
		--set-string podAnnotations.rollme=$(shell date +%s) \
		--wait

# ---- Data stores ----------------------------------------------------------------
.PHONY: deploy-mysql
deploy-mysql: ## Install/upgrade the MySQL chart
	$(HELM) upgrade --install mysql deploy/charts/mysql --namespace $(APP_NAMESPACE) --wait

.PHONY: deploy-redis
deploy-redis: ## Install/upgrade the Redis chart
	$(HELM) upgrade --install redis deploy/charts/redis --namespace $(APP_NAMESPACE) --wait

# ---- orders-api -------------------------------------------------------------------
.PHONY: build-orders
build-orders: ## Build the orders-api image (API and worker)
	docker build -t $(ORDERS_IMAGE) orders-api

.PHONY: import-orders
import-orders: ## Import the orders-api image into k3d
	k3d image import -c $(CLUSTER_NAME) $(ORDERS_IMAGE)

.PHONY: deploy-orders
deploy-orders: ## Install/upgrade the orders-api chart (runs migrations first)
	$(HELM) upgrade --install orders-api deploy/charts/orders-api \
		--namespace $(APP_NAMESPACE) \
		--set image.repository=$(firstword $(subst :, ,$(ORDERS_IMAGE))) \
		--set image.tag=$(IMAGE_TAG) \
		--set-string podAnnotations.rollme=$(shell date +%s) \
		--wait

.PHONY: test-orders
test-orders: ## Run the orders-api test suite (in Docker, no local PHP needed)
	docker run --rm -v "$(CURDIR)/orders-api":/app -w /app composer:2 php artisan test
