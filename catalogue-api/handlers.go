package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

// Attribute keys for this service's spans. Custom attributes get an app
// prefix so they can't clash with OpenTelemetry's semantic conventions.
var (
	attrProductID     = attribute.Key("catalogue.product.id")
	attrQuantity      = attribute.Key("catalogue.quantity")
	attrStockLeft     = attribute.Key("catalogue.stock.remaining")
	attrCacheHit      = attribute.Key("catalogue.cache.hit")
	attrProductsCount = attribute.Key("catalogue.products.count")
	attrChaosDelayMS  = attribute.Key("catalogue.chaos.delay_ms")
)

type server struct {
	store  *Store
	cache  *productCache
	logger *slog.Logger
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /products", s.listProducts)
	mux.HandleFunc("GET /products/{id}", s.getProduct)
	mux.HandleFunc("POST /stock/reserve", s.reserveStock)
	mux.HandleFunc("POST /stock/restock", s.restockStock)
	mux.HandleFunc("GET /chaos", s.chaos)
	mux.HandleFunc("GET /healthz", s.healthz)

	// otelhttp starts a server span per request (continuing the caller's
	// trace if it sent a traceparent header) and names it from the mux's
	// route pattern, e.g. "GET /products/{id}". Health checks are skipped.
	traced := otelhttp.NewHandler(requestLogger(s.logger, mux), "catalogue-api",
		otelhttp.WithFilter(func(r *http.Request) bool { return r.URL.Path != "/healthz" }),
	)
	return traced
}

func (s *server) listProducts(w http.ResponseWriter, r *http.Request) {
	products := s.store.List()
	trace.SpanFromContext(r.Context()).SetAttributes(attrProductsCount.Int(len(products)))
	s.logger.InfoContext(r.Context(), "listed products", "count", len(products))
	writeJSON(w, http.StatusOK, products)
}

func (s *server) getProduct(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	id := r.PathValue("id")
	trace.SpanFromContext(ctx).SetAttributes(attrProductID.String(id))

	p, hit := s.lookupCache(ctx, id)
	if hit {
		writeJSON(w, http.StatusOK, p)
		return
	}

	p, err := s.store.Get(ctx, id)
	if errors.Is(err, ErrNotFound) {
		writeError(w, http.StatusNotFound, "product not found")
		return
	}
	s.cache.Set(p)
	writeJSON(w, http.StatusOK, p)
}

// lookupCache wraps the cache read in its own span, so traces show hits and
// misses (and how often a miss goes on to the store).
func (s *server) lookupCache(ctx context.Context, id string) (Product, bool) {
	ctx, span := tracer.Start(ctx, "cache.lookup", trace.WithAttributes(attrProductID.String(id)))
	defer span.End()

	p, hit := s.cache.Get(id)
	span.SetAttributes(attrCacheHit.Bool(hit))

	result := "miss"
	if hit {
		result = "hit"
	}
	s.logger.InfoContext(ctx, "product cache lookup", "product_id", id, "result", result)
	return p, hit
}

type stockRequest struct {
	ProductID string `json:"product_id"`
	Quantity  int    `json:"quantity"`
}

type reserveResponse struct {
	ProductID string `json:"product_id"`
	Reserved  int    `json:"reserved"`
	Remaining int    `json:"remaining"`
}

func (s *server) reserveStock(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	span := trace.SpanFromContext(ctx)

	req, ok := decodeStockRequest(w, r)
	if !ok {
		return
	}
	span.SetAttributes(attrProductID.String(req.ProductID), attrQuantity.Int(req.Quantity))

	s.checkWarehouse(ctx)

	p, err := s.store.Reserve(ctx, req.ProductID, req.Quantity)
	switch {
	case errors.Is(err, ErrNotFound):
		writeError(w, http.StatusNotFound, "product not found")
		return
	case errors.Is(err, ErrInsufficientStock):
		// A normal business outcome, not an error: record it as an event
		// on the span rather than failing it.
		span.AddEvent("insufficient stock", trace.WithAttributes(attrStockLeft.Int(p.Stock)))
		s.logger.WarnContext(r.Context(), "insufficient stock",
			"product_id", req.ProductID, "requested", req.Quantity, "available", p.Stock)
		writeError(w, http.StatusConflict, "insufficient stock")
		return
	case err != nil:
		s.logger.ErrorContext(r.Context(), "reserve stock failed", "product_id", req.ProductID, "error", err)
		writeError(w, http.StatusInternalServerError, "could not reserve stock")
		return
	}

	s.cache.Delete(p.ID)
	span.SetAttributes(attrStockLeft.Int(p.Stock))
	s.logger.InfoContext(r.Context(), "stock reserved",
		"product_id", p.ID, "quantity", req.Quantity, "remaining", p.Stock)
	writeJSON(w, http.StatusOK, reserveResponse{ProductID: p.ID, Reserved: req.Quantity, Remaining: p.Stock})
}

type restockResponse struct {
	ProductID string `json:"product_id"`
	Added     int    `json:"added"`
	Stock     int    `json:"stock"`
}

// restockStock stands in for a warehouse delivery. The load generator calls
// it to stop the shop selling out during long runs.
func (s *server) restockStock(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	span := trace.SpanFromContext(ctx)

	req, ok := decodeStockRequest(w, r)
	if !ok {
		return
	}
	span.SetAttributes(attrProductID.String(req.ProductID), attrQuantity.Int(req.Quantity))

	p, err := s.store.Restock(ctx, req.ProductID, req.Quantity)
	switch {
	case errors.Is(err, ErrNotFound):
		writeError(w, http.StatusNotFound, "product not found")
		return
	case err != nil:
		s.logger.ErrorContext(r.Context(), "restock failed", "product_id", req.ProductID, "error", err)
		writeError(w, http.StatusInternalServerError, "could not restock")
		return
	}

	s.cache.Delete(p.ID)
	span.SetAttributes(attrStockLeft.Int(p.Stock))
	s.logger.InfoContext(r.Context(), "stock restocked",
		"product_id", p.ID, "quantity", req.Quantity, "stock", p.Stock)
	writeJSON(w, http.StatusOK, restockResponse{ProductID: p.ID, Added: req.Quantity, Stock: p.Stock})
}

// checkWarehouse simulates a slow call to a downstream warehouse system, as
// its own span so the latency shows up clearly in the trace waterfall.
func (s *server) checkWarehouse(ctx context.Context) {
	_, span := tracer.Start(ctx, "warehouse.check")
	defer span.End()

	time.Sleep(time.Duration(20+rand.IntN(180)) * time.Millisecond)
}

// decodeStockRequest parses and validates a reserve/restock body, writing an
// error response and returning false if it is invalid.
func decodeStockRequest(w http.ResponseWriter, r *http.Request) (stockRequest, bool) {
	var req stockRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return req, false
	}
	if req.ProductID == "" || req.Quantity < 1 {
		writeError(w, http.StatusUnprocessableEntity, "product_id and a positive quantity are required")
		return req, false
	}
	return req, true
}

// chaos sleeps for up to 2s and fails ~20% of the time, to give the
// dashboards some latency and errors to show.
func (s *server) chaos(w http.ResponseWriter, r *http.Request) {
	span := trace.SpanFromContext(r.Context())

	delay := time.Duration(rand.IntN(2000)) * time.Millisecond
	span.SetAttributes(attrChaosDelayMS.Int64(delay.Milliseconds()))
	time.Sleep(delay)

	if rand.Float64() < 0.2 {
		// otelhttp marks 5xx spans as errors anyway; recording the error adds
		// an "exception" event with the message.
		err := errors.New("chaos strikes")
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		s.logger.ErrorContext(r.Context(), "chaos failure", "delay_ms", delay.Milliseconds())
		writeError(w, http.StatusInternalServerError, "chaos strikes")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"delay_ms": delay.Milliseconds()})
}

func (s *server) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
