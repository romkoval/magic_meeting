package main

import (
	"sync"
	"time"
)

// RateLimiter is an in-memory token bucket per device. It is enough for a
// single VPS; state is lost on restart, which is acceptable for abuse limits.
type RateLimiter struct {
	mu      sync.Mutex
	perMin  float64
	buckets map[string]*bucket
	now     func() time.Time
}

type bucket struct {
	tokens float64
	last   time.Time
}

func NewRateLimiter(perMin int) *RateLimiter {
	return &RateLimiter{perMin: float64(perMin), buckets: map[string]*bucket{}, now: time.Now}
}

func (l *RateLimiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	if len(l.buckets) > 50_000 {
		l.evictIdle(now)
	}
	b, ok := l.buckets[key]
	if !ok {
		b = &bucket{tokens: l.perMin, last: now}
		l.buckets[key] = b
	}
	b.tokens += now.Sub(b.last).Minutes() * l.perMin
	if b.tokens > l.perMin {
		b.tokens = l.perMin
	}
	b.last = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

func (l *RateLimiter) evictIdle(now time.Time) {
	for k, b := range l.buckets {
		if now.Sub(b.last) > 10*time.Minute {
			delete(l.buckets, k)
		}
	}
}
