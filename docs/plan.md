# OTEL Play — Implementation Plan

A toy shop running on k3d. Its only purpose is to demo OpenTelemetry flowing into the Grafana stack and Honeycomb.

The work is in two parts:

1. **Build the apps** with no telemetry at all, just structured logs to stdout that you read with `kubectl logs`.
2. **Add observability**: install the backends, then instrument each existing app in turn. This keeps the OTel changes for each service small and easy to see as their own diffs.

## Architecture

**Part 1: the apps**
```
browser ─► web (Next.js) ─► orders-api (Laravel, php-fpm+nginx) ─► catalogue-api (Go)
                                   │  └─► MySQL
                                   └─► Redis queue ─► orders-worker (Laravel queue:work)
```

**Part 2: telemetry added on top**
```
all apps ─OTLP─► otel-collector ─┬─► Alloy ─► Tempo (traces) / Mimir (metrics) / Loki (logs) ─► Grafana
                                 └─► Honeycomb (otlphttp, x-honeycomb-team)
browser ─OTLP/http─► web /api/otel (proxy) ─► otel-collector
```

## Decisions

- Laravel uses **MySQL**, with **Redis** as the queue. PHP runs as **php-fpm + nginx**. The worker is a separate Deployment built from the same image.
- In Part 1, every app writes **JSON logs to stdout**: Go `slog` JSON handler, Laravel `stderr` channel with the JSON formatter, and Next.js `console`.
- Pipeline (Part 2): apps send OTLP to a single **OTel Collector (contrib)**, which fans out to **Alloy** (feeding Tempo, Mimir and Loki) and to **Honeycomb**.
- Browser OTLP goes through a Next.js route (`/api/otel`), so the collector needs no CORS setup and isn't exposed.
- Host access uses the k3d **Traefik ingress** on `*.localhost`: `shop.`, `orders.`, `catalogue.`, `grafana.`.
- Each component gets **its own Helm chart** under `deploy/charts/`. Third-party charts are configured with values files in `deploy/helm/`.
- catalogue-api stores products and stock in a **JSON file on a PersistentVolume**.
- Extras: k6 load generator, provisioned Grafana dashboards, structured logs over OTLP.

## Repo layout

- `catalogue-api/` — Go service and Dockerfile
- `orders-api/` — Laravel app and Dockerfile. One image runs php-fpm by default and the queue worker with `queue:work` as its args; nginx is a sidecar
- `web/` — Next.js app (TypeScript, app router) and Dockerfile
- `deploy/k3d/` — cluster config
- `deploy/charts/` — our own charts: `catalogue-api`, `orders-api` (web and worker Deployments, migrate Job), `web`, `mysql`, `redis`, `dashboards`
- `deploy/helm/` — values files for the third-party charts (grafana, loki, mimir, tempo, alloy, otel-collector)
- `loadgen/` — k6 script
- `Makefile`, `.env.example` (`HONEYCOMB_API_KEY`), `docs/`

## Services

The **Telemetry** columns describe what gets added in Part 2. In Part 1, each endpoint only writes a log line.

### catalogue-api (Go, net/http)

| Endpoint | Behaviour | Telemetry (Part 2) |
|---|---|---|
| `GET /products` | Product list read from a JSON file on a PVC, seeded from an embedded default on first start | span, `catalogue.products.listed` counter |
| `GET /products/{id}` | Product plus a fake cache lookup | child span `cache.lookup`, `catalogue.cache.requests{result=hit\|miss}` |
| `POST /stock/reserve` | Decrements stock and writes it back to the file (mutex + atomic rename), with random latency | span attributes product.id/qty, `catalogue.stock.level` observable gauge |
| `GET /chaos` | Random delay or a 500 | error spans, `http.server.duration` histogram |
| `GET /healthz` | Probe | not traced |

### orders-api (Laravel)

| Endpoint | Behaviour | Telemetry (Part 2) |
|---|---|---|
| `POST /api/orders` | Creates an order, calls catalogue `/stock/reserve`, dispatches `ProcessOrder` | Laravel→Go trace spans, `orders.created` counter, `orders.value` histogram |
| `GET /api/orders/{id}` | Order status | DB spans |
| `GET /api/orders` | Recent orders | span |
| `POST /api/orders/{id}/cancel` | Dispatches `CancelOrder` | `orders.cancelled` counter |

### orders-worker (same image, `php artisan queue:work redis`)

- `ProcessOrder`: fake payment (a sleep, with ~10% failures that get retried), then dispatches `SendConfirmation`.
- `SendConfirmation`: writes a log line, standing in for an email.
- Part 2:
  - the job payload carries the trace context, so a trace continues from the HTTP request into the jobs
  - metrics: `jobs.processed{job,status}`, `jobs.duration` histogram, `jobs.queue_wait` histogram

### web (Next.js + TypeScript)

- Pages:
  - product grid, fetched server-side from catalogue-api
  - product detail with **Add to basket**
  - basket with **Checkout**, which POSTs from the browser to orders-api
  - order status page that polls until the order is paid or failed
- Part 2:
  - Server: `instrumentation.ts` with the Node SDK (http/fetch auto-instrumentation).
  - Browser:
    - Web SDK with fetch and user-interaction instrumentation
    - custom spans `basket.add` and `checkout.submit`
    - counters `ui.basket.added` and `ui.checkout.clicked`
    - exports to `/api/otel/v1/{traces,metrics,logs}`
    - `propagateTraceHeaderCorsUrls` covers `orders.localhost`

## Gotchas

- **PHP metrics:** each php-fpm request is short-lived, so cumulative counters would reset on every request. Use delta temporality (`OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta`) and add a `deltatocumulative` processor in the collector before the Mimir path. Honeycomb accepts delta as is.
- **CORS:** in Part 1, orders-api must allow requests from `shop.localhost`. In Part 2, it must also allow the `traceparent`/`tracestate` headers.
- **MySQL and Redis images:** Bitnami charts and images are no longer freely maintained. Our own charts use the official images instead.
- **Mimir size:** use `mimir-distributed` with small replica counts and low resource values, or monolithic mode. Give Docker about 6–8 GB RAM for k3d.
- **Local images:** build them locally and load them with `k3d image import`, using `imagePullPolicy: IfNotPresent`.
- **catalogue-api storage:** its data lives on a ReadWriteOnce PVC (`local-path`), so it runs with `replicas: 1` and the `Recreate` strategy.

---

# Part 1 — The apps (no telemetry)

## Stage 0 — Scaffolding
- [x] Create the directory layout, `.gitignore`, and `.env.example` with `HONEYCOMB_API_KEY` and an optional `HONEYCOMB_DATASET`. The app dirs (`catalogue-api/`, `orders-api/`, `web/`) are created in their own stages, because `composer create-project` and `create-next-app` need an empty target dir
- [x] Makefile skeleton: `help`, `check-deps` (docker, k3d, kubectl, helm, k6), `config`, config vars (`CLUSTER_NAME`, `KUBE_CONTEXT`, namespaces, image names and tags)

## Stage 1 — Cluster
- [x] `make cluster-up`: k3d cluster from `deploy/k3d/cluster.yaml` (1 server, 2 agents), with `--port "$(HTTP_PORT):80@loadbalancer"` (default 80). Safe to re-run. `make cluster-down` deletes it
- [x] Namespaces: `observability`, `shop` (`make namespaces`, also run by `cluster-up`)
- [x] Verify: `make cluster-status` shows 3 Ready nodes and Traefik 1/1, and `curl -H "Host: test.localhost" localhost` returns Traefik's 404

## Stage 2 — catalogue-api (Go)
- [x] Go module (standard library only), `net/http` ServeMux, and a `slog` JSON logger to stdout that logs each request (method, path, status, duration)
- [x] File-backed product store (`DATA_PATH`, default `/data/products.json`), seeded from an embedded default if the file is missing
- [x] Endpoints from the table above
- [x] Multi-stage Dockerfile (distroless, non-root, with a writable data dir). The user must be numeric (`65532`), or Kubernetes' `runAsNonRoot` check refuses to start the container
- [x] Make targets: `build-catalogue`, `import-catalogue`, `deploy-catalogue`. These set the per-service pattern that Stage 6 generalises. `deploy-catalogue` sets a timestamp pod annotation so a re-imported `dev` image still rolls the pod
- [x] Helm chart `deploy/charts/catalogue-api`: Deployment (1 replica, Recreate), PVC mounted at `/data` (kept on uninstall), Service, Ingress `catalogue.localhost`, liveness/readiness on `/healthz`
- [x] Verify:
  - curl the endpoints via `catalogue.localhost`
  - `kubectl logs` shows JSON request logs
  - reserve stock, delete the pod, and check the stock level survived

## Stage 3 — MySQL, Redis, orders-api (Laravel)
- [x] Helm charts `deploy/charts/mysql` (StatefulSet, PVC, Secret, official `mysql:8.4` image) and `deploy/charts/redis` (Deployment, Service, `redis:7.4-alpine`, no persistence)
- [x] New Laravel 13 app, created with the `composer:2` Docker image since there's no local PHP:
  - `Order` and `OrderItem` models with their migration, plus an `OrderStatus` enum (pending, paid, failed, rejected, cancelled)
  - the endpoints from the table above
  - `CatalogueClient`, which prices each line with `GET /products/{id}` and then calls `/stock/reserve`
- [x] `ProcessOrder` and `CancelOrder` job stubs so dispatching works. They only log for now, and the real logic comes in Stage 4
- [x] Logging: `LOG_CHANNEL=stderr` with the JSON formatter. `LogRequest` middleware writes one line per request (skipping `/up`). Logs cover order created, rejected and queued, plus each catalogue reservation
- [x] CORS config allowing origins from `CORS_ALLOWED_ORIGINS` (default `http://shop.localhost`)
- [x] Feature tests (`make test-orders`, run in Docker): create, rejected, unknown product, catalogue outage, show/list, cancel, CORS
- [x] Dockerfile:
  - `php:8.4-fpm` with `pdo_mysql`, `redis`, `opcache`, `pcntl` via `install-php-extensions`; the `opentelemetry` extension comes in Part 2
  - fpm config sets `clear_env = no` so the pod's env reaches PHP, and turns off fpm's own access log
  - the entrypoint runs `php artisan optimize` at start-up
  - a single image for the API and the worker; nginx is a sidecar (`nginx-unprivileged`) that sends every request to `index.php`
- [x] Helm chart `deploy/charts/orders-api`:
  - web Deployment (php + nginx containers), Service, Ingress `orders.localhost`
  - migration Job as a Helm `pre-install,pre-upgrade` hook. Its env comes only from values and the mysql chart's Secret, since the hook runs before this chart's own resources exist
  - an `APP_KEY` Secret, generated once and kept across upgrades with `lookup`
- [x] Make targets: `deploy-mysql`, `deploy-redis`, `build-orders`, `import-orders`, `deploy-orders`, `test-orders`
- [x] Verify:
  - `POST /api/orders` creates rows in MySQL and decrements stock in catalogue-api
  - an order that can't be reserved returns 409 with status `rejected`; an unknown product returns 422
  - jobs land on the Redis queue (`orders-api-database-queues:default`)
  - `kubectl logs` shows JSON logs from both services

## Stage 4 — orders-worker
- [x] Jobs:
  - `ProcessOrder` charges through a fake `PaymentGateway` (200–1500ms; 10% timeouts that get retried, 5% declines that fail at once). Rates are set in `config/orders.php` with `PAYMENT_*` env vars. It runs 3 tries with backoff `[2, 5]`, and its `failed()` hook marks the order failed. It skips orders that were cancelled while queued
  - `CancelOrder` cancels pending or paid orders
  - `SendConfirmation` logs a fake email, or skips if there's no email address
- [x] Logging:
  - queue event listeners in `AppServiceProvider` write `job started`, `job processed` (with `duration_ms`), `job attempt failed` (with `will_retry`) and `job failed`, each with the job name, uuid, queue and attempt. This is the worker's equivalent of `LogRequest`
  - `order_id` goes on Laravel's `Context` rather than `Log::withContext`, so it's carried from the HTTP request into the job payload and cleared between jobs
- [x] Worker Deployment in the `orders-api` chart (`worker.enabled`, `worker.replicas`). It uses the same image with `args: [php, artisan, queue:work, redis, --sleep=1, --quiet, --max-time=3600]`. `--quiet` drops queue:work's non-JSON console lines, and `args` (not `command`) keeps the entrypoint's `optimize`
- [x] Rollout fix: `preStop` sleeps on the web pod (nginx 5s, php 8s), so `make deploy-orders` doesn't drop requests with a 502 while Traefik catches up. Tested: 80 of 80 requests succeeded during a rollout
- [x] Tests: `OrderJobsTest` covers paid + confirmation queued, decline, transient error rethrown, the `failed()` hook, and cancel before process
- [x] Verify:
  - orders move from pending to paid, failed (declined) or cancelled
  - worker logs show `job attempt failed … will_retry: true` followed by attempt 2 succeeding
  - a burst of orders builds a backlog, and retries queue behind it

## Stage 5 — web (Next.js)
- [ ] `create-next-app` (TypeScript, app router) with the pages from the services section. The basket lives in client state or localStorage
- [ ] Server-side fetches use the in-cluster catalogue URL. Browser calls use `orders.localhost`, configured by env vars
- [ ] Dockerfile (standalone output) and Helm chart `deploy/charts/web`: Deployment, Service, Ingress `shop.localhost`
- [ ] Verify: browse `shop.localhost`, add an item to the basket, check out, and the order status page reaches paid or failed

## Stage 6 — App wiring
- [ ] Make targets:
  - `make build`: docker build for every service
  - `make import`: `k3d image import`
  - `make deploy`: `helm upgrade --install` for each chart in `deploy/charts/`; the hook runs migrations
  - `make deploy-<chart>`: deploy one chart
  - `make lint`: `helm lint` on every chart
  - `make apps-up`: cluster → build → import → deploy
- [ ] `make logs SVC=...`, plus `make open` to print the URLs
- [ ] Verify: `make cluster-down && make apps-up` brings the whole shop back from scratch

## Stage 7 — Load generator
- [ ] `loadgen/script.js` (k6): browses products, views a product, creates orders, and occasionally cancels an order or calls chaos
- [ ] `make load` runs k6 locally against `*.localhost`, with an option to run it as a k8s Job
- [ ] Verify: `make load` runs cleanly, and the logs show steady traffic across all services

---

# Part 2 — Observability

## Stage 8 — Grafana stack (Helm)
- [ ] `make helm-repos` (grafana, open-telemetry)
- [ ] Install Loki (single binary, filesystem storage, native OTLP enabled)
- [ ] Install Mimir (minimal values, OTLP endpoint `/otlp`)
- [ ] Install Tempo (single binary, OTLP gRPC receiver)
- [ ] Install Alloy: `otelcol.receiver.otlp` → batch → exporters to Tempo (otlp), Mimir (otlphttp `/otlp`) and Loki (otlphttp `/otlp`)
- [ ] Install Grafana with provisioned datasources, including Tempo↔Loki↔Mimir links (traces-to-logs, exemplars), and ingress `grafana.localhost`
- [ ] `make observability-up` runs all of the above
- [ ] Verify: Grafana loads and the datasources pass their health checks

## Stage 9 — OTel Collector + Honeycomb
- [ ] `make secrets` creates the `honeycomb` Secret from `.env`
- [ ] Install the opentelemetry-collector chart (contrib image, deployment mode):
  - Receivers: otlp grpc and http
  - Processors: memory_limiter, k8sattributes, resource, deltatocumulative (on the metrics→alloy pipeline only), batch
  - Exporters: `otlp/alloy`, `otlphttp/honeycomb`
- [ ] Verify with a `telemetrygen` Job (`make smoke-telemetry`): traces appear in both Tempo and Honeycomb

## Stage 10 — Instrument catalogue-api
- [ ] OTel SDK setup: resource, OTLP gRPC exporters for traces and metrics, wrap the mux with `otelhttp`
- [ ] Custom spans and metrics from the table, including a span around file reads and writes
- [ ] Add `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_SERVICE_NAME` to the chart values
- [ ] Verify: curl the endpoints, see spans and metrics in Grafana and Honeycomb

## Stage 11 — Instrument orders-api + worker
- [ ] Add the `opentelemetry` extension to the Dockerfile (`install-php-extensions opentelemetry`) and `OTEL_PHP_AUTOLOAD_ENABLED=true`
- [ ] Composer packages: `open-telemetry/sdk`, `open-telemetry/exporter-otlp`, `open-telemetry/opentelemetry-auto-laravel`, `open-telemetry/opentelemetry-auto-guzzle` (or psr18)
- [ ] Custom metrics through a small `Telemetry` service (Meter from `Globals`), with delta temporality
- [ ] Add `traceparent`/`tracestate` to the allowed CORS headers
- [ ] Worker:
  - check that the auto-laravel queue instrumentation links each job span to the trace that dispatched it; if it doesn't, inject and extract `traceparent` in the job payload by hand
  - job metrics (processed, duration, queue wait), with the MeterProvider export interval set so the long-running process actually exports
- [ ] Verify: `POST /api/orders` produces one trace with Laravel, MySQL and HTTP→Go spans, continuing into the worker spans, with retries visible

## Stage 12 — Instrument web
- [ ] Server-side `instrumentation.ts` (NodeSDK, OTLP exporters)
- [ ] Browser telemetry provider (a client component):
  - WebTracerProvider and MeterProvider
  - fetch and user-interaction instrumentation
  - custom spans and counters
- [ ] `/api/otel/[...path]` route that proxies OTLP/http to the collector
- [ ] Verify: one checkout click produces one trace through browser → orders-api → catalogue-api → worker

## Stage 13 — Logs over OTLP
- [ ] Switch the existing stdout logs to also go over OTLP with trace_id/span_id:
  - Go: `otelslog` bridge
  - Laravel: `open-telemetry/opentelemetry-logger-monolog` handler
  - Node and browser: LoggerProvider
- [ ] Verify: logs show in Loki with trace IDs, the Grafana trace→logs link works, and logs show in Honeycomb

## Stage 14 — Dashboards
- [ ] Helm chart `deploy/charts/dashboards`: dashboard JSON files under `dashboards/`, rendered into ConfigMaps labelled `grafana_dashboard=1` (via `.Files.Glob`) and picked up by the Grafana sidecar
- [ ] Dashboards:
  - Shop overview: orders/min, order value, checkout clicks
  - Catalogue: latency, cache hit ratio, stock gauge, chaos errors
  - Queue: jobs processed/failed, duration, queue wait

## Stage 15 — Final wiring & docs
- [ ] `make up`: cluster → observability → collector → build → import → deploy. `make down` deletes everything
- [ ] README: prerequisites, `cp .env.example .env`, `make up`, URLs, demo walkthrough, and how Part 1 → Part 2 shows adding OTel to an existing system

---

## End-to-end verification
1. On a fresh machine with the prerequisites installed, `make up` brings up the whole stack.
2. Open `shop.localhost`, add a product to the basket and check out. In Grafana Explore (Tempo), one trace covers web (browser + server), orders-api, MySQL, catalogue-api and orders-worker. The same trace shows in Honeycomb.
3. Run `make load` for a few minutes. The dashboards fill with data, and the Loki logs link to their traces.
