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

# ---- Observability (Grafana stack) -------------------------------------------------
# Third-party charts, pinned. Values live in deploy/helm/<release>.yaml.
HELM_REPOS := \
	grafana=https://grafana.github.io/helm-charts \
	grafana-community=https://grafana-community.github.io/helm-charts \
	prometheus-community=https://prometheus-community.github.io/helm-charts \
	open-telemetry=https://open-telemetry.github.io/opentelemetry-helm-charts

prometheus_CHART := prometheus-community/prometheus
prometheus_VERSION := 29.38.1
loki_CHART := grafana-community/loki
loki_VERSION := 19.4.0
tempo_CHART := grafana-community/tempo
tempo_VERSION := 3.2.1
alloy_CHART := grafana/alloy
alloy_VERSION := 1.14.3
grafana_CHART := grafana-community/grafana
grafana_VERSION := 14.0.1
otel-collector_CHART := open-telemetry/opentelemetry-collector
otel-collector_VERSION := 0.177.0

# Backends first, then Alloy (which sends to them), the OTel Collector (which
# sends to Alloy and Honeycomb), and Grafana (which reads the backends).
OBSERVABILITY := prometheus loki tempo alloy otel-collector grafana

HONEYCOMB_API_ENDPOINT    ?= api.honeycomb.io:443
# Honeycomb environments put OTLP metrics in a dataset called "metrics" whatever
# this says (checked in the UI); other names may still apply to Honeycomb Classic.
HONEYCOMB_METRICS_DATASET ?= metrics

.PHONY: helm-repos
helm-repos: ## Add/update the third-party Helm repos
	@for r in $(HELM_REPOS); do helm repo add --force-update $${r%%=*} $${r#*=} >/dev/null; done
	helm repo update $(foreach r,$(HELM_REPOS),$(firstword $(subst =, ,$(r))))

install-%: ## Install/upgrade one observability chart: install-loki | install-otel-collector | ...
	$(if $(filter $*,$(OBSERVABILITY)),,$(error Unknown observability chart "$*". Choose from: $(OBSERVABILITY)))
	$(HELM) upgrade --install $* $($*_CHART) --version $($*_VERSION) \
		--namespace $(OBS_NAMESPACE) -f deploy/helm/$*.yaml --wait --timeout 5m

.PHONY: secrets
# The key is read from the shell environment ($$HONEYCOMB_API_KEY, exported from
# .env above) rather than expanded by make, so it never shows up in `make -n`
# output or make's command echo.
secrets: ## Create/update the honeycomb Secret from .env (HONEYCOMB_API_KEY)
	@test -n "$$HONEYCOMB_API_KEY" || { echo "HONEYCOMB_API_KEY is not set. cp .env.example .env and add your key."; exit 1; }
	@$(KUBECTL) -n $(OBS_NAMESPACE) create secret generic honeycomb \
		--from-literal=api-key="$$HONEYCOMB_API_KEY" \
		--from-literal=api-endpoint="$(HONEYCOMB_API_ENDPOINT)" \
		--from-literal=metrics-dataset="$(HONEYCOMB_METRICS_DATASET)" \
		--dry-run=client -o yaml | $(KUBECTL) apply -f -

.PHONY: observability-up
observability-up: helm-repos secrets ## Install the Grafana stack, the OTel Collector and the Honeycomb Secret
	@for c in $(OBSERVABILITY); do $(MAKE) --no-print-directory install-$$c || exit 1; done
	@echo ""
	@echo "  Grafana: http://grafana.localhost$(PORT_SUFFIX)  (anonymous admin; or admin/admin)"
	@echo ""

TELEMETRYGEN_IMAGE := ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.163.0

.PHONY: smoke-telemetry
smoke-telemetry: ## Send test traces, metrics and logs through the OTel Collector (service.name=otel-smoke-test)
	@for signal in traces metrics logs; do \
		echo "Sending $$signal..."; \
		$(KUBECTL) -n $(OBS_NAMESPACE) run telemetrygen-$$signal --rm -i --restart=Never --quiet \
			--image=$(TELEMETRYGEN_IMAGE) -- $$signal \
			--otlp-endpoint=otel-collector.$(OBS_NAMESPACE).svc:4317 --otlp-insecure \
			--service=otel-smoke-test --duration=5s --rate=5 >/dev/null 2>&1 || exit 1; \
	done
	@echo "Done. Look for service otel-smoke-test in Grafana (Explore) and Honeycomb."

.PHONY: observability-status
observability-status: ## Show the Grafana stack's pods
	$(KUBECTL) -n $(OBS_NAMESPACE) get pods,svc,ingress

.PHONY: alloy-ui
alloy-ui: ## Port-forward the Alloy UI (pipeline graph) to http://localhost:12345
	$(KUBECTL) -n $(OBS_NAMESPACE) port-forward svc/alloy 12345:12345

# ---- Load generator -----------------------------------------------------------------
VUS      ?= 5
DURATION ?= 5m

.PHONY: load
load: ## Generate traffic from this machine with k6 (VUS=5 DURATION=5m)
	VUS=$(VUS) DURATION=$(DURATION) k6 run loadgen/script.js

.PHONY: load-job
load-job: ## Generate traffic from inside the cluster with a k6 Job (VUS, DURATION)
	$(KUBECTL) -n $(APP_NAMESPACE) create configmap loadgen-script \
		--from-file=loadgen/script.js --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) -n $(APP_NAMESPACE) create configmap loadgen-env \
		--from-literal=VUS=$(VUS) --from-literal=DURATION=$(DURATION) \
		--dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) -n $(APP_NAMESPACE) delete job loadgen --ignore-not-found
	$(KUBECTL) -n $(APP_NAMESPACE) apply -f loadgen/job.yaml
	@echo "Follow it with: make logs SVC=job/loadgen   Stop it with: make load-stop"

.PHONY: load-stop
load-stop: ## Stop the in-cluster k6 Job
	$(KUBECTL) -n $(APP_NAMESPACE) delete job loadgen --ignore-not-found
