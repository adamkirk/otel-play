package main

import (
	"context"
	"fmt"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
)

var meter = otel.Meter("github.com/adamkirk/otel-play/catalogue-api")

var attrReservationResult = attribute.Key("catalogue.reservation.outcome")

// metrics holds this service's custom instruments. HTTP request metrics
// (http.server.request.duration etc.) come from otelhttp.
type metrics struct {
	cacheRequests     metric.Int64Counter
	productViews      metric.Int64Counter
	reservations      metric.Int64Counter
	reservedUnits     metric.Int64Counter
	warehouseDuration metric.Float64Histogram
}

func newMetrics(store *Store) (*metrics, error) {
	var m metrics
	var err error

	if m.cacheRequests, err = meter.Int64Counter("catalogue.cache.requests",
		metric.WithDescription("Product cache lookups, by result (hit or miss)."),
		metric.WithUnit("{request}"),
	); err != nil {
		return nil, err
	}
	if m.productViews, err = meter.Int64Counter("catalogue.product.views",
		metric.WithDescription("Product detail requests, by product."),
		metric.WithUnit("{view}"),
	); err != nil {
		return nil, err
	}
	if m.reservations, err = meter.Int64Counter("catalogue.reservations",
		metric.WithDescription("Stock reservation attempts, by outcome."),
		metric.WithUnit("{reservation}"),
	); err != nil {
		return nil, err
	}
	if m.reservedUnits, err = meter.Int64Counter("catalogue.stock.reserved",
		metric.WithDescription("Units of stock reserved, by product."),
		metric.WithUnit("{unit}"),
	); err != nil {
		return nil, err
	}
	if m.warehouseDuration, err = meter.Float64Histogram("catalogue.warehouse.duration",
		metric.WithDescription("Time spent waiting on the (simulated) warehouse system."),
		metric.WithUnit("s"),
		metric.WithExplicitBucketBoundaries(0.025, 0.05, 0.075, 0.1, 0.125, 0.15, 0.175, 0.2, 0.25),
	); err != nil {
		return nil, err
	}

	// An observable gauge is read at export time instead of being recorded as
	// things happen, which suits "current value" metrics like stock levels.
	if _, err := meter.Int64ObservableGauge("catalogue.stock.level",
		metric.WithDescription("Units currently in stock, by product."),
		metric.WithUnit("{unit}"),
		metric.WithInt64Callback(func(_ context.Context, o metric.Int64Observer) error {
			for _, p := range store.List() {
				o.Observe(int64(p.Stock), metric.WithAttributes(attrProductID.String(p.ID)))
			}
			return nil
		}),
	); err != nil {
		return nil, fmt.Errorf("stock level gauge: %w", err)
	}

	return &m, nil
}

func (m *metrics) recordCacheLookup(ctx context.Context, result string) {
	m.cacheRequests.Add(ctx, 1, metric.WithAttributes(attrCacheResult.String(result)))
}

func (m *metrics) recordReservation(ctx context.Context, productID, outcome string, qty int) {
	m.reservations.Add(ctx, 1, metric.WithAttributes(attrReservationResult.String(outcome)))
	if outcome == "reserved" {
		m.reservedUnits.Add(ctx, int64(qty), metric.WithAttributes(attrProductID.String(productID)))
	}
}

// recordWarehouseWait records with the request's context, so the SDK can
// attach the current trace as an exemplar: Grafana can then jump from a slow
// bucket on the histogram to an example trace.
func (m *metrics) recordWarehouseWait(ctx context.Context, d time.Duration) {
	m.warehouseDuration.Record(ctx, d.Seconds())
}
