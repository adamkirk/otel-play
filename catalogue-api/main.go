package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// stdoutLogger is for logging when OpenTelemetry isn't running: before it's
// set up and after it's shut down.
var stdoutLogger = slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: logLevel()}))

func main() {
	if err := run(); err != nil {
		stdoutLogger.Error("fatal", "error", err)
		os.Exit(1)
	}
}

func run() error {
	addr := ":" + env("PORT", "8080")
	dataPath := env("DATA_PATH", "/data/products.json")

	shutdownTelemetry, err := setupTelemetry(context.Background())
	if err != nil {
		return err
	}
	defer func() {
		// Flush any spans, metrics and logs still buffered before exiting.
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := shutdownTelemetry(ctx); err != nil {
			stdoutLogger.Error("telemetry shutdown failed", "error", err)
		}
	}()

	// Logs go to stdout and over OTLP from here on.
	logger := newLogger(logLevel())

	store, seeded, err := OpenStore(dataPath)
	if err != nil {
		return err
	}
	logger.Info("product store opened", "path", dataPath, "seeded", seeded, "products", len(store.List()))

	m, err := newMetrics(store)
	if err != nil {
		return err
	}

	srv := &server{store: store, cache: newProductCache(30 * time.Second), metrics: m, logger: logger}
	httpServer := &http.Server{
		Addr:              addr,
		Handler:           srv.routes(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		logger.Info("listening", "addr", addr)
		errCh <- httpServer.ListenAndServe()
	}()

	select {
	case err := <-errCh:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
		logger.Info("shutting down")
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return httpServer.Shutdown(shutdownCtx)
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func logLevel() slog.Level {
	var level slog.Level
	if err := level.UnmarshalText([]byte(env("LOG_LEVEL", "info"))); err != nil {
		return slog.LevelInfo
	}
	return level
}
