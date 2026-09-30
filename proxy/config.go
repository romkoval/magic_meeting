package main

import (
	"errors"
	"os"
	"strconv"
	"strings"
	"time"
)

// Config is read from the environment only. The Groq key never lives in the
// repository or in the app; it is set in the systemd unit's EnvironmentFile.
type Config struct {
	ListenAddr      string
	GroqAPIKey      string
	GroqBaseURL     string
	STTModel        string
	LLMModel        string
	ClientTokens    []string // pilot-only bearer tokens until App Attest lands
	RateLimitPerMin int
	MaxUploadBytes  int64
	MaxLLMBodyBytes int64
	UpstreamTimeout time.Duration
}

func LoadConfig() (Config, error) {
	c := Config{
		ListenAddr:      env("LISTEN_ADDR", "127.0.0.1:8080"),
		GroqAPIKey:      os.Getenv("GROQ_API_KEY"),
		GroqBaseURL:     strings.TrimRight(env("GROQ_BASE_URL", "https://api.groq.com/openai/v1"), "/"),
		STTModel:        env("GROQ_STT_MODEL", "whisper-large-v3"),
		LLMModel:        env("GROQ_LLM_MODEL", "llama-3.3-70b-versatile"),
		RateLimitPerMin: envInt("RATE_LIMIT_PER_MIN", 30),
		MaxUploadBytes:  int64(envInt("MAX_UPLOAD_MB", 25)) << 20,
		MaxLLMBodyBytes: int64(envInt("MAX_LLM_BODY_KB", 1024)) << 10,
		UpstreamTimeout: time.Duration(envInt("UPSTREAM_TIMEOUT_SEC", 180)) * time.Second,
	}
	for _, t := range strings.Split(os.Getenv("CLIENT_TOKENS"), ",") {
		if t = strings.TrimSpace(t); t != "" {
			c.ClientTokens = append(c.ClientTokens, t)
		}
	}
	if c.GroqAPIKey == "" {
		return c, errors.New("GROQ_API_KEY is not set")
	}
	return c, nil
}

func env(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v, err := strconv.Atoi(strings.TrimSpace(os.Getenv(key))); err == nil && v > 0 {
		return v
	}
	return def
}
