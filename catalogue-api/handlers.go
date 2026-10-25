package main

import (
	"encoding/json"
	"errors"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"time"
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
	mux.HandleFunc("GET /chaos", s.chaos)
	mux.HandleFunc("GET /healthz", s.healthz)
	return requestLogger(s.logger, mux)
}

func (s *server) listProducts(w http.ResponseWriter, r *http.Request) {
	products := s.store.List()
	s.logger.InfoContext(r.Context(), "listed products", "count", len(products))
	writeJSON(w, http.StatusOK, products)
}

func (s *server) getProduct(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")

	if p, ok := s.cache.Get(id); ok {
		s.logger.InfoContext(r.Context(), "product cache lookup", "product_id", id, "result", "hit")
		writeJSON(w, http.StatusOK, p)
		return
	}
	s.logger.InfoContext(r.Context(), "product cache lookup", "product_id", id, "result", "miss")

	p, err := s.store.Get(id)
	if errors.Is(err, ErrNotFound) {
		writeError(w, http.StatusNotFound, "product not found")
		return
	}
	s.cache.Set(p)
	writeJSON(w, http.StatusOK, p)
}

type reserveRequest struct {
	ProductID string `json:"product_id"`
	Quantity  int    `json:"quantity"`
}

type reserveResponse struct {
	ProductID string `json:"product_id"`
	Reserved  int    `json:"reserved"`
	Remaining int    `json:"remaining"`
}

func (s *server) reserveStock(w http.ResponseWriter, r *http.Request) {
	var req reserveRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.ProductID == "" || req.Quantity < 1 {
		writeError(w, http.StatusUnprocessableEntity, "product_id and a positive quantity are required")
		return
	}

	// Simulate a slow downstream (warehouse system, say).
	time.Sleep(time.Duration(20+rand.IntN(180)) * time.Millisecond)

	p, err := s.store.Reserve(req.ProductID, req.Quantity)
	switch {
	case errors.Is(err, ErrNotFound):
		writeError(w, http.StatusNotFound, "product not found")
		return
	case errors.Is(err, ErrInsufficientStock):
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
	s.logger.InfoContext(r.Context(), "stock reserved",
		"product_id", p.ID, "quantity", req.Quantity, "remaining", p.Stock)
	writeJSON(w, http.StatusOK, reserveResponse{ProductID: p.ID, Reserved: req.Quantity, Remaining: p.Stock})
}

// chaos sleeps for up to 2s and fails ~20% of the time, to give the
// dashboards some latency and errors to show.
func (s *server) chaos(w http.ResponseWriter, r *http.Request) {
	delay := time.Duration(rand.IntN(2000)) * time.Millisecond
	time.Sleep(delay)

	if rand.Float64() < 0.2 {
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
