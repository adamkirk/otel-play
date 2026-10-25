package main

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"testing"

	"go.opentelemetry.io/otel/trace"
)

func TestTraceContextHandlerAddsIDs(t *testing.T) {
	var buf bytes.Buffer
	logger := slog.New(traceContextHandler{slog.NewJSONHandler(&buf, nil)})

	sc := trace.NewSpanContext(trace.SpanContextConfig{
		TraceID:    trace.TraceID{1, 2, 3},
		SpanID:     trace.SpanID{4, 5, 6},
		TraceFlags: trace.FlagsSampled,
	})
	logger.InfoContext(trace.ContextWithSpanContext(context.Background(), sc), "with span")
	logger.InfoContext(context.Background(), "without span")

	lines := bytes.Split(bytes.TrimSpace(buf.Bytes()), []byte("\n"))
	var withSpan, withoutSpan map[string]any
	if err := json.Unmarshal(lines[0], &withSpan); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(lines[1], &withoutSpan); err != nil {
		t.Fatal(err)
	}

	if withSpan["trace_id"] != sc.TraceID().String() || withSpan["span_id"] != sc.SpanID().String() {
		t.Fatalf("missing span IDs: %v", withSpan)
	}
	if _, ok := withoutSpan["trace_id"]; ok {
		t.Fatalf("unexpected trace_id without a span: %v", withoutSpan)
	}
}

func TestMinLevelHandler(t *testing.T) {
	var buf bytes.Buffer
	logger := slog.New(minLevelHandler{slog.NewJSONHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug}), slog.LevelWarn})

	logger.Info("dropped")
	logger.With("k", "v").Warn("kept")

	if got := bytes.Count(buf.Bytes(), []byte("\n")); got != 1 {
		t.Fatalf("got %d lines, want 1: %s", got, buf.String())
	}
}
