package main

import (
	"sync"
	"time"
)

// productCache is a deliberately simple TTL cache in front of the store.
// It exists so GET /products/{id} has hits and misses worth observing.
type productCache struct {
	mu      sync.Mutex
	ttl     time.Duration
	entries map[string]cacheEntry
}

type cacheEntry struct {
	product Product
	expires time.Time
}

func newProductCache(ttl time.Duration) *productCache {
	return &productCache{ttl: ttl, entries: map[string]cacheEntry{}}
}

func (c *productCache) Get(id string) (Product, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()

	e, ok := c.entries[id]
	if !ok || time.Now().After(e.expires) {
		delete(c.entries, id)
		return Product{}, false
	}
	return e.product, true
}

func (c *productCache) Set(p Product) {
	c.mu.Lock()
	defer c.mu.Unlock()

	c.entries[p.ID] = cacheEntry{product: p, expires: time.Now().Add(c.ttl)}
}

func (c *productCache) Delete(id string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	delete(c.entries, id)
}
