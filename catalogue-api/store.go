package main

import (
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

//go:embed seed.json
var seedProducts []byte

var (
	ErrNotFound          = errors.New("product not found")
	ErrInsufficientStock = errors.New("insufficient stock")
)

type Product struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	PricePence  int    `json:"price_pence"`
	Stock       int    `json:"stock"`
}

// Store keeps products in memory and persists every change to a JSON file,
// so stock levels survive pod restarts.
type Store struct {
	mu       sync.RWMutex
	path     string
	products []Product
}

// OpenStore loads products from path, seeding it from the embedded default
// if the file does not exist yet. The bool reports whether it was seeded.
func OpenStore(path string) (*Store, bool, error) {
	s := &Store{path: path}

	data, err := os.ReadFile(path)
	seeded := false
	if errors.Is(err, os.ErrNotExist) {
		data, seeded = seedProducts, true
	} else if err != nil {
		return nil, false, fmt.Errorf("read %s: %w", path, err)
	}

	if err := json.Unmarshal(data, &s.products); err != nil {
		return nil, false, fmt.Errorf("parse products: %w", err)
	}

	if seeded {
		if err := s.save(); err != nil {
			return nil, false, err
		}
	}

	return s, seeded, nil
}

func (s *Store) List() []Product {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]Product, len(s.products))
	copy(out, s.products)
	return out
}

func (s *Store) Get(id string) (Product, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	for _, p := range s.products {
		if p.ID == id {
			return p, nil
		}
	}
	return Product{}, ErrNotFound
}

// Reserve decrements stock for a product and persists the change. It returns
// the updated product.
func (s *Store) Reserve(id string, qty int) (Product, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	for i := range s.products {
		p := &s.products[i]
		if p.ID != id {
			continue
		}
		if p.Stock < qty {
			return *p, ErrInsufficientStock
		}

		p.Stock -= qty
		if err := s.save(); err != nil {
			p.Stock += qty
			return *p, err
		}
		return *p, nil
	}
	return Product{}, ErrNotFound
}

// Restock adds stock to a product and persists the change. It returns the
// updated product.
func (s *Store) Restock(id string, qty int) (Product, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	for i := range s.products {
		p := &s.products[i]
		if p.ID != id {
			continue
		}

		p.Stock += qty
		if err := s.save(); err != nil {
			p.Stock -= qty
			return *p, err
		}
		return *p, nil
	}
	return Product{}, ErrNotFound
}

// save writes to a temp file and renames it over the real one, so a crash
// mid-write never leaves a truncated file. Callers must hold the lock (or be
// in OpenStore before the store is shared).
func (s *Store) save() error {
	data, err := json.MarshalIndent(s.products, "", "  ")
	if err != nil {
		return fmt.Errorf("encode products: %w", err)
	}

	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return fmt.Errorf("create data dir: %w", err)
	}

	tmp, err := os.CreateTemp(filepath.Dir(s.path), ".products-*.json")
	if err != nil {
		return fmt.Errorf("create temp file: %w", err)
	}
	defer os.Remove(tmp.Name())

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("write temp file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp file: %w", err)
	}
	if err := os.Rename(tmp.Name(), s.path); err != nil {
		return fmt.Errorf("replace %s: %w", s.path, err)
	}
	return nil
}
