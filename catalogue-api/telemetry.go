package main

import (
	"context"
	"errors"
	"fmt"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

// tracer is used for this service's own spans (the HTTP server spans come
// from otelhttp).
var tracer = otel.Tracer("github.com/adamkirk/otel-play/catalogue-api")

// setupTelemetry installs the global OpenTelemetry providers and returns a
// function that flushes and shuts them down.
//
// Everything is configured with the standard OTEL_* environment variables
// (set by the Helm chart), so there's nothing deployment-specific here:
//
//	OTEL_SERVICE_NAME            catalogue-api
//	OTEL_EXPORTER_OTLP_ENDPOINT  http://otel-collector.observability.svc:4317
//	OTEL_RESOURCE_ATTRIBUTES     extra resource attributes, e.g. service.version
func setupTelemetry(ctx context.Context) (shutdown func(context.Context) error, err error) {
	res, err := resource.New(ctx,
		resource.WithFromEnv(),      // OTEL_SERVICE_NAME, OTEL_RESOURCE_ATTRIBUTES
		resource.WithTelemetrySDK(), // telemetry.sdk.{name,language,version}
		resource.WithHost(),
	)
	if err != nil {
		return nil, fmt.Errorf("build resource: %w", err)
	}

	traceExporter, err := otlptracegrpc.New(ctx)
	if err != nil {
		return nil, fmt.Errorf("create trace exporter: %w", err)
	}
	tracerProvider := sdktrace.NewTracerProvider(
		sdktrace.WithResource(res),
		sdktrace.WithBatcher(traceExporter),
	)
	otel.SetTracerProvider(tracerProvider)

	// W3C traceparent/tracestate and baggage, so traces join up with the
	// services that call us.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	return func(ctx context.Context) error {
		return errors.Join(tracerProvider.Shutdown(ctx))
	}, nil
}
