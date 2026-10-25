package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"time"

	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/otel/trace"
)

// newLogger returns a logger that writes every record twice:
//
//   - as JSON on stdout (for kubectl logs), with trace_id/span_id added when
//     there's an active span
//   - over OTLP via the otelslog bridge, to the global LoggerProvider. The
//     SDK attaches the span context to the record itself.
//
// Pass the request's context (logger.InfoContext(ctx, ...)) for the trace
// IDs to be picked up.
func newLogger(level slog.Level) *slog.Logger {
	stdout := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level})
	otlp := otelslog.NewHandler("github.com/adamkirk/otel-play/catalogue-api")

	return slog.New(slog.NewMultiHandler(
		traceContextHandler{stdout},
		minLevelHandler{otlp, level},
	))
}

// traceContextHandler adds trace_id and span_id attributes from the context's
// span, so stdout lines can be matched to traces too.
type traceContextHandler struct{ slog.Handler }

func (h traceContextHandler) Handle(ctx context.Context, r slog.Record) error {
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		r.AddAttrs(
			slog.String("trace_id", sc.TraceID().String()),
			slog.String("span_id", sc.SpanID().String()),
		)
	}
	return h.Handler.Handle(ctx, r)
}

func (h traceContextHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return traceContextHandler{h.Handler.WithAttrs(attrs)}
}

func (h traceContextHandler) WithGroup(name string) slog.Handler {
	return traceContextHandler{h.Handler.WithGroup(name)}
}

// minLevelHandler drops records below a level. The otelslog handler sends
// everything, so this applies LOG_LEVEL to the OTLP side too.
type minLevelHandler struct {
	slog.Handler
	level slog.Level
}

func (h minLevelHandler) Enabled(ctx context.Context, l slog.Level) bool {
	return l >= h.level && h.Handler.Enabled(ctx, l)
}

func (h minLevelHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return minLevelHandler{h.Handler.WithAttrs(attrs), h.level}
}

func (h minLevelHandler) WithGroup(name string) slog.Handler {
	return minLevelHandler{h.Handler.WithGroup(name), h.level}
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

// requestLogger logs one line per request. Health checks are skipped to keep
// the logs readable. It runs inside otelhttp's handler, so r.Context() carries
// the request's span and each line is linked to its trace.
func requestLogger(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" {
			next.ServeHTTP(w, r)
			return
		}

		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)

		level := slog.LevelInfo
		if rec.status >= 500 {
			level = slog.LevelError
		}
		logger.LogAttrs(r.Context(), level, "request",
			slog.String("method", r.Method),
			slog.String("path", r.URL.Path),
			slog.Int("status", rec.status),
			slog.Int64("duration_ms", time.Since(start).Milliseconds()),
		)
	})
}
