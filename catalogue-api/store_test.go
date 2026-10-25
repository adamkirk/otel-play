package main

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
)

func TestStoreSeedsAndPersists(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "products.json")

	s, seeded, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if !seeded {
		t.Fatal("expected store to be seeded on first open")
	}

	before, err := s.Get(ctx, "tea-earl-grey")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Reserve(ctx, "tea-earl-grey", 3); err != nil {
		t.Fatal(err)
	}

	reopened, seeded, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if seeded {
		t.Fatal("expected existing file to be loaded, not re-seeded")
	}
	after, _ := reopened.Get(ctx, "tea-earl-grey")
	if after.Stock != before.Stock-3 {
		t.Fatalf("stock = %d, want %d", after.Stock, before.Stock-3)
	}
}

func TestRestock(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "products.json")
	s, _, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}

	before, _ := s.Get(ctx, "mug-enamel")
	if _, err := s.Restock(ctx, "mug-enamel", 5); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Restock(ctx, "nope", 5); !errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}

	reopened, _, _ := OpenStore(path)
	if after, _ := reopened.Get(ctx, "mug-enamel"); after.Stock != before.Stock+5 {
		t.Fatalf("stock = %d, want %d", after.Stock, before.Stock+5)
	}
}

func TestReserveErrors(t *testing.T) {
	ctx := context.Background()
	s, _, err := OpenStore(filepath.Join(t.TempDir(), "products.json"))
	if err != nil {
		t.Fatal(err)
	}

	if _, err := s.Reserve(ctx, "nope", 1); !errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}

	p, _ := s.Get(ctx, "grinder-hand")
	if _, err := s.Reserve(ctx, p.ID, p.Stock+1); !errors.Is(err, ErrInsufficientStock) {
		t.Fatalf("err = %v, want ErrInsufficientStock", err)
	}
	if got, _ := s.Get(ctx, p.ID); got.Stock != p.Stock {
		t.Fatalf("stock changed after failed reserve: %d -> %d", p.Stock, got.Stock)
	}
}
