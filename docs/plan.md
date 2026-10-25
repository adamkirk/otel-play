# OTEL Play — Implementation Plan

A toy shop running on k3d. Its only purpose is to demo OpenTelemetry flowing into the Grafana stack and Honeycomb.

## Architecture

```
browser ─► web (Next.js) ─► orders-api (Laravel, php-fpm+nginx) ─► catalogue-api (Go)
                                   │  └─► MySQL
                                   └─► Redis queue ─► orders-worker (Laravel queue:work)

all apps ─OTLP─► otel-collector ─┬─► Alloy ─► Tempo (traces) / Mimir (metrics) / Loki (logs) ─► Grafana
                                 └─► Honeycomb (otlphttp, x-honeycomb-team)
browser ─OTLP/http─► web /api/otel (proxy) ─► otel-collector
```

## Decisions

- Laravel uses **MySQL**, with **Redis** as the queue. PHP runs as **php-fpm + nginx**. The worker is a separate Deployment built from the same image.
- Pipeline: apps send OTLP to a single **OTel Collector (contrib)**, which fans out to **Alloy** (feeding Tempo, Mimir and Loki) and to **Honeycomb**.
- Browser OTLP goes through a Next.js route (`/api/otel`), so the collector needs no CORS setup and isn't exposed.
- Host access uses the k3d **Traefik ingress** on `*.localhost`: `shop.`, `orders.`, `catalogue.`, `grafana.`.
- Each component gets **its own Helm chart** under `deploy/charts/`. Third-party charts are configured with values files in `deploy/helm/`.
- catalogue-api stores products and stock in a **JSON file on a PersistentVolume**.
- Extras: k6 load generator, provisioned Grafana dashboards, structured logs over OTLP.

## Repo layout

- `catalogue-api/` — Go service and Dockerfile
- `orders-api/` — Laravel app and Dockerfile, with two targets: `web` (nginx + fpm) and `worker` (queue:work)
- `web/` — Next.js app (TypeScript, app router) and Dockerfile
- `deploy/helm/` — values files for the third-party charts (grafana, loki, mimir, tempo, alloy, otel-collector)
- `deploy/charts/` — our own charts: `catalogue-api`, `orders-api` (web and worker Deployments, migrate Job), `web`, `mysql`, `redis`, `dashboards`
- `loadgen/` — k6 script
- `Makefile`, `.env.example` (`HONEYCOMB_API_KEY`), `docs/`

## Services

### catalogue-api (Go, net/http + otelhttp, OTel Go SDK)

| Endpoint | Behaviour | Telemetry |
|---|---|---|
| `GET /products` | Product list read from a JSON file on a PVC, seeded from an embedded default on first start | span, `catalogue.products.listed` counter |
| `GET /products/{id}` | Product plus a fake cache lookup | child span `cache.lookup`, `catalogue.cache.requests{result=hit\|miss}` |
| `POST /stock/reserve` | Decrements stock and writes it back to the file (mutex + atomic rename), with random latency | span attributes product.id/qty, `catalogue.stock.level` observable gauge |
| `GET /chaos` | Random delay or a 500 | error spans, `http.server.duration` histogram |
| `GET /healthz` | Probe | not traced |

### orders-api (Laravel, OTel PHP extension + opentelemetry-auto-laravel + SDK)

| Endpoint | Behaviour | Telemetry |
|---|---|---|
| `POST /api/orders` | Creates an order, calls catalogue `/stock/reserve`, dispatches `ProcessOrder` | Laravel→Go trace spans, `orders.created` counter, `orders.value` histogram |
| `GET /api/orders/{id}` | Order status | DB spans |
| `GET /api/orders` | Recent orders | span |
| `POST /api/orders/{id}/cancel` | Dispatches `CancelOrder` | `orders.cancelled` counter |

### orders-worker (same image, `php artisan queue:work redis`)

- `ProcessOrder`: fake payment (a sleep, with ~10% failures that get retried), then dispatches `SendConfirmation`.
- `SendConfirmation`: writes a log line, standing in for an email.
- The job payload carries the trace context, so a trace continues from the HTTP request into the jobs.
- Metrics: `jobs.processed{job,status}`, `jobs.duration` histogram, `jobs.queue_wait` histogram.

### web (Next.js + TypeScript)

- Pages:
  - product grid, fetched server-side from catalogue-api
  - product detail with **Add to basket**
  - basket with **Checkout**, which POSTs from the browser to orders-api
  - order status page that polls until the order is paid or failed
- Server: `instrumentation.ts` with the Node SDK (http/fetch auto-instrumentation).
- Browser:
  - Web SDK with fetch and user-interaction instrumentation
  - custom spans `basket.add` and `checkout.submit`
  - counters `ui.basket.added` and `ui.checkout.clicked`
  - exports to `/api/otel/v1/{traces,metrics,logs}`
  - `propagateTraceHeaderCorsUrls` covers `orders.localhost`

## Gotchas

- **PHP metrics:** each php-fpm request is short-lived, so cumulative counters would reset on every request. Use delta temporality (`OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta`) and add a `deltatocumulative` processor in the collector before the Mimir path. Honeycomb accepts delta as is.
- **CORS:** orders-api must allow the `traceparent`/`tracestate` headers from `shop.localhost`.
- **MySQL and Redis images:** Bitnami charts and images are no longer freely maintained. Our own charts use the official images instead.
- **Mimir size:** use `mimir-distributed` with small replica counts and low resource values, or monolithic mode. Give Docker about 6–8 GB RAM for k3d.
- **Local images:** build them locally and load them with `k3d image import`, using `imagePullPolicy: IfNotPresent`.
- **catalogue-api storage:** its data lives on a ReadWriteOnce PVC (`local-path`), so it runs with `replicas: 1` and the `Recreate` strategy.

---

## Stage 0 — Scaffolding
- [x] Create the directory layout, `.gitignore`, and `.env.example` with `HONEYCOMB_API_KEY` and an optional `HONEYCOMB_DATASET`. The app dirs (`catalogue-api/`, `orders-api/`, `web/`) are created in their own stages, because `composer create-project` and `create-next-app` need an empty target dir
- [x] Makefile skeleton: `help`, `check-deps` (docker, k3d, kubectl, helm, k6), `config`, config vars (`CLUSTER_NAME`, `KUBE_CONTEXT`, namespaces, image names and tags)

## Stage 1 — Cluster
- [ ] `make cluster-up`: k3d cluster with `-p "80:80@loadbalancer"`, 1 server and 2 agents. `make cluster-down` deletes it
- [ ] Namespaces: `observability`, `shop`
- [ ] Verify: `kubectl get nodes` lists the nodes and Traefik responds on localhost:80

## Stage 2 — Grafana stack (Helm)
- [ ] `make helm-repos` (grafana, open-telemetry)
- [ ] Install Loki (single binary, filesystem storage, native OTLP enabled)
- [ ] Install Mimir (minimal values, OTLP endpoint `/otlp`)
- [ ] Install Tempo (single binary, OTLP gRPC receiver)
- [ ] Install Alloy: `otelcol.receiver.otlp` → batch → exporters to Tempo (otlp), Mimir (otlphttp `/otlp`) and Loki (otlphttp `/otlp`)
- [ ] Install Grafana with provisioned datasources, including Tempo↔Loki↔Mimir links (traces-to-logs, exemplars), and ingress `grafana.localhost`
- [ ] `make observability-up` runs all of the above
- [ ] Verify: Grafana loads and the datasources pass their health checks

## Stage 3 — OTel Collector + Honeycomb
- [ ] `make secrets` creates the `honeycomb` Secret from `.env`
- [ ] Install the opentelemetry-collector chart (contrib image, deployment mode):
  - Receivers: otlp grpc and http
  - Processors: memory_limiter, k8sattributes, resource, deltatocumulative (on the metrics→alloy pipeline only), batch
  - Exporters: `otlp/alloy`, `otlphttp/honeycomb`
- [ ] Verify with a `telemetrygen` Job (`make smoke-telemetry`): traces appear in both Tempo and Honeycomb

## Stage 4 — catalogue-api (Go)
- [ ] Go module and OTel SDK setup: resource, OTLP gRPC exporters for traces, metrics and logs, `otelslog` bridge
- [ ] File-backed product store (`DATA_PATH`, default `/data/products.json`), seeded from an embedded default if the file is missing, with a span around file reads and writes
- [ ] Endpoints and custom metrics/spans as in the table above
- [ ] Multi-stage Dockerfile (distroless, non-root, with a writable data dir)
- [ ] Helm chart `deploy/charts/catalogue-api`: Deployment (1 replica, Recreate), PVC mounted at `/data`, Service, Ingress `catalogue.localhost`, env vars `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_SERVICE_NAME`
- [ ] Verify:
  - curl the endpoints and see spans and metrics in Grafana and Honeycomb
  - reserve stock, delete the pod, and check the stock level survived

## Stage 5 — MySQL, Redis, orders-api (Laravel)
- [ ] Helm charts `deploy/charts/mysql` (StatefulSet, PVC, Secret, official image) and `deploy/charts/redis` (Deployment, Service)
- [ ] New Laravel app with an Order model, its migration, and the endpoints from the table above
- [ ] Composer packages: `open-telemetry/sdk`, `open-telemetry/exporter-otlp`, `open-telemetry/opentelemetry-auto-laravel`, `open-telemetry/opentelemetry-auto-guzzle` (or psr18), `open-telemetry/opentelemetry-logger-monolog`
- [ ] Custom metrics through a small `Telemetry` service (Meter from `Globals`)
- [ ] Dockerfile:
  - php-fpm with `pecl install opentelemetry redis`
  - nginx, via supervisord or a sidecar container
  - a `worker` target
- [ ] Helm chart `deploy/charts/orders-api`:
  - web Deployment, Service, Ingress `orders.localhost`
  - migration Job as a Helm `pre-install,pre-upgrade` hook
  - shared ConfigMap/Secret for env
- [ ] CORS config in Laravel
- [ ] Verify: `POST /api/orders` produces one trace with Laravel, MySQL and HTTP→Go spans

## Stage 6 — orders-worker
- [ ] `ProcessOrder`, `CancelOrder` and `SendConfirmation` jobs
- [ ] Check that the auto-laravel queue instrumentation links each job span to the trace that dispatched it. If it doesn't, inject and extract `traceparent` in the job payload by hand
- [ ] Job metrics (processed, duration, queue wait), with the MeterProvider export interval set so the long-running process actually exports
- [ ] Worker Deployment in the `orders-api` chart (`worker.enabled`, `worker.replicas`), using the `worker` image target
- [ ] Verify: the order trace continues into the worker spans, and retries are visible

## Stage 7 — web (Next.js)
- [ ] `create-next-app` (TypeScript, app router) with the pages from the services section
- [ ] Server-side `instrumentation.ts` (NodeSDK, OTLP exporters)
- [ ] Browser telemetry provider (a client component):
  - WebTracerProvider, MeterProvider and LoggerProvider
  - fetch and user-interaction instrumentation
  - custom spans and counters
- [ ] `/api/otel/[...path]` route that proxies OTLP/http to the collector
- [ ] Dockerfile (standalone output) and Helm chart `deploy/charts/web`: Deployment, Service, Ingress `shop.localhost`
- [ ] Verify: one checkout click produces one trace through browser → orders-api → catalogue-api → worker

## Stage 8 — Logs
- [ ] Structured logs with trace_id/span_id from every service over OTLP (Go slog bridge, Monolog handler, Node and browser logs)
- [ ] Verify: logs show in Loki with trace IDs, the Grafana trace→logs link works, and logs show in Honeycomb

## Stage 9 — Dashboards
- [ ] Helm chart `deploy/charts/dashboards`: dashboard JSON files under `dashboards/`, rendered into ConfigMaps labelled `grafana_dashboard=1` (via `.Files.Glob`) and picked up by the Grafana sidecar
- [ ] Dashboards:
  - Shop overview: orders/min, order value, checkout clicks
  - Catalogue: latency, cache hit ratio, stock gauge, chaos errors
  - Queue: jobs processed/failed, duration, queue wait

## Stage 10 — Load generator
- [ ] `loadgen/script.js` (k6): browses products, views a product, creates orders, and occasionally cancels an order or calls chaos
- [ ] `make load` runs k6 locally against `*.localhost`, with an option to run it as a k8s Job

## Stage 11 — Wiring & docs
- [ ] Make targets:
  - `make build`: docker build for every service
  - `make import`: `k3d image import`
  - `make deploy`: `helm upgrade --install` for each chart in `deploy/charts/`; the hook runs migrations
  - `make deploy-<chart>`: deploy one chart
  - `make lint`: `helm lint` on every chart
  - `make up`: cluster → observability → collector → build → import → deploy
  - `make down`
- [ ] `make logs SVC=...`, plus `make open` to print the URLs
- [ ] README: prerequisites, `cp .env.example .env`, `make up`, URLs, demo walkthrough

---

## End-to-end verification
1. On a fresh machine with the prerequisites installed, `make up` brings up the whole stack.
2. Open `shop.localhost`, add a product to the basket and check out. In Grafana Explore (Tempo), one trace covers web (browser + server), orders-api, MySQL, catalogue-api and orders-worker. The same trace shows in Honeycomb.
3. Run `make load` for a few minutes. The dashboards fill with data, and the Loki logs link to their traces.
