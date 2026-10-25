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

# ---- App services -----------------------------------------------------------------
# Each app service has a short name, a source dir, an image and a Helm release
# (whose chart lives at deploy/charts/<release>). The pattern rules below build,
# import and deploy any of them, e.g. `make build-web` or `make deploy-orders`.
APP_SERVICES := catalogue orders web

catalogue_DIR     := catalogue-api
catalogue_IMAGE   := $(CATALOGUE_IMAGE)
catalogue_RELEASE := catalogue-api

orders_DIR     := orders-api
orders_IMAGE   := $(ORDERS_IMAGE)
orders_RELEASE := orders-api

web_DIR     := web
web_IMAGE   := $(WEB_IMAGE)
web_RELEASE := web

# Charts that need no image of ours.
DATA_STORES := mysql redis

# Deploy order matters: orders-api's migration hook needs MySQL up first.
DEPLOY_ORDER := $(DATA_STORES) $(APP_SERVICES)

check-service = $(if $(filter $*,$(APP_SERVICES)),,$(error Unknown service "$*". Choose from: $(APP_SERVICES)))

build-%: ## Build one service image: build-catalogue | build-orders | build-web
	$(check-service)
	docker build -t $($*_IMAGE) $($*_DIR)

import-%: ## Import one service image into k3d: import-catalogue | ...
	$(check-service)
	k3d image import -c $(CLUSTER_NAME) $($*_IMAGE)

# The rollme annotation makes a re-imported image with the same tag still roll
# the pods.
deploy-%: ## Install/upgrade one chart: deploy-catalogue | deploy-orders | deploy-web | deploy-mysql | deploy-redis
	$(if $(filter $*,$(DATA_STORES)), \
		$(HELM) upgrade --install $* deploy/charts/$* --namespace $(APP_NAMESPACE) --wait, \
		$(check-service) \
		$(HELM) upgrade --install $($*_RELEASE) deploy/charts/$($*_RELEASE) \
			--namespace $(APP_NAMESPACE) \
			--set image.repository=$(firstword $(subst :, ,$($*_IMAGE))) \
			--set image.tag=$(IMAGE_TAG) \
			--set-string podAnnotations.rollme=$(shell date +%s) \
			--wait)

.PHONY: build
build: ## Build all service images
	@for s in $(APP_SERVICES); do $(MAKE) --no-print-directory build-$$s || exit 1; done

.PHONY: import
import: ## Import all service images into k3d
	@for s in $(APP_SERVICES); do $(MAKE) --no-print-directory import-$$s || exit 1; done

.PHONY: deploy
deploy: ## Install/upgrade every chart, data stores first
	@for s in $(DEPLOY_ORDER); do $(MAKE) --no-print-directory deploy-$$s || exit 1; done

.PHONY: lint
lint: ## Lint all of our Helm charts
	helm lint deploy/charts/*

.PHONY: test
test: test-catalogue test-orders ## Run all test suites

.PHONY: test-catalogue
test-catalogue: ## Run the catalogue-api tests (in Docker, no local Go needed)
	docker run --rm -v "$(CURDIR)/catalogue-api":/src -w /src golang:1.26 go test ./...

.PHONY: test-orders
test-orders: ## Run the orders-api tests (in Docker, no local PHP needed)
	docker run --rm -v "$(CURDIR)/orders-api":/app -w /app composer:2 php artisan test

.PHONY: apps-up
apps-up: ## Create the cluster and build, import and deploy the whole shop
	@$(MAKE) --no-print-directory cluster-up
	@$(MAKE) --no-print-directory build
	@$(MAKE) --no-print-directory import
	@$(MAKE) --no-print-directory deploy
	@$(MAKE) --no-print-directory open

# ---- Day to day --------------------------------------------------------------------
.PHONY: status
status: ## Show the shop's pods, services and ingresses
	$(KUBECTL) -n $(APP_NAMESPACE) get pods,svc,ingress

# SVC is a Deployment name (catalogue-api, orders-api, orders-api-worker, web,
# redis) or any kubectl resource, e.g. SVC=statefulset/mysql.
.PHONY: logs
logs: ## Follow a service's logs: make logs SVC=orders-api-worker
	@test -n "$(SVC)" || { echo 'Usage: make logs SVC=<name>  (catalogue-api, orders-api, orders-api-worker, web, redis, statefulset/mysql)'; exit 1; }
	$(KUBECTL) -n $(APP_NAMESPACE) logs -f --all-containers --prefix --tail=50 \
		$(if $(findstring /,$(SVC)),$(SVC),deploy/$(SVC))

PORT_SUFFIX := $(if $(filter 80,$(HTTP_PORT)),,:$(HTTP_PORT))

.PHONY: open
open: ## Print the shop's URLs
	@echo ""
	@echo "  Shop:          http://shop.localhost$(PORT_SUFFIX)"
	@echo "  Orders API:    http://orders.localhost$(PORT_SUFFIX)/api/orders"
	@echo "  Catalogue API: http://catalogue.localhost$(PORT_SUFFIX)/products"
	@echo ""
