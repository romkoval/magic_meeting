package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"path/filepath"
	"strings"
	"time"
)

type Server struct {
	cfg     Config
	groq    *Groq
	limiter *RateLimiter
}

func NewServer(cfg Config, groq *Groq) *Server {
	return &Server{cfg: cfg, groq: groq, limiter: NewRateLimiter(cfg.RateLimitPerMin)}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.Handle("POST /v1/transcribe", s.guard(http.HandlerFunc(s.handleTranscribe)))
	mux.Handle("POST /v1/llm", s.guard(http.HandlerFunc(s.handleLLM)))
	return logRequests(mux)
}

// guard checks the client token and the per-device rate limit.
// App Attest replaces the pilot token before the App Store release.
func (s *Server) guard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if len(s.cfg.ClientTokens) > 0 && !s.tokenValid(r) {
			writeError(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		device := strings.TrimSpace(r.Header.Get("X-Device-ID"))
		if device == "" || len(device) > 128 {
			writeError(w, http.StatusBadRequest, "X-Device-ID header is required")
			return
		}
		if !s.limiter.Allow(device) {
			w.Header().Set("Retry-After", "10")
			writeError(w, http.StatusTooManyRequests, "rate limit exceeded")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) tokenValid(r *http.Request) bool {
	got, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok {
		return false
	}
	for _, t := range s.cfg.ClientTokens {
		if subtle.ConstantTimeCompare([]byte(got), []byte(t)) == 1 {
			return true
		}
	}
	return false
}

// handleTranscribe accepts multipart/form-data: file (audio), glossary (one
// term per line, optional), language (ISO-639-1, optional).
func (s *Server) handleTranscribe(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, s.cfg.MaxUploadBytes+64<<10)
	if err := r.ParseMultipartForm(8 << 20); err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			writeError(w, http.StatusRequestEntityTooLarge, "audio file is too large")
			return
		}
		writeError(w, http.StatusBadRequest, "expected multipart form with a file field")
		return
	}
	defer r.MultipartForm.RemoveAll()

	file, header, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, "file field is required")
		return
	}
	defer file.Close()

	name := filepath.Base(header.Filename)
	if name == "." || name == "/" || filepath.Ext(name) == "" {
		name = "audio.m4a"
	}
	glossary := strings.Split(r.FormValue("glossary"), "\n")
	language := strings.ToLower(strings.TrimSpace(r.FormValue("language")))
	if len(language) > 8 {
		writeError(w, http.StatusBadRequest, "invalid language")
		return
	}

	res, err := s.groq.Transcribe(r.Context(), name, file, glossary, language)
	if err != nil {
		writeUpstreamError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (s *Server) handleLLM(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, s.cfg.MaxLLMBodyBytes)
	var req LLMRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	setLogOp(r, req.Op)
	result, err := RunLLM(r.Context(), s.groq.Chat, req)
	if err != nil {
		var bad ErrBadInput
		switch {
		case errors.As(err, &bad):
			writeError(w, http.StatusBadRequest, bad.Error())
		case errors.Is(err, errBadModelOutput):
			writeError(w, http.StatusBadGateway, err.Error())
		default:
			writeUpstreamError(w, err)
		}
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"op": req.Op, "result": result})
}

func writeUpstreamError(w http.ResponseWriter, err error) {
	var up *UpstreamError
	switch {
	case errors.As(err, &up) && up.Status == http.StatusTooManyRequests:
		w.Header().Set("Retry-After", "20")
		writeError(w, http.StatusServiceUnavailable, "recognition service is busy, retry later")
	case errors.As(err, &up) && up.Status == http.StatusRequestEntityTooLarge:
		writeError(w, http.StatusRequestEntityTooLarge, "audio file is too large")
	case errors.Is(err, context.DeadlineExceeded):
		writeError(w, http.StatusGatewayTimeout, "recognition service timed out")
	default:
		log.Printf("upstream error: %v", err)
		writeError(w, http.StatusBadGateway, "recognition service error")
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// Request logging records only metadata. Audio, transcripts, commands and
// model answers never reach the log.

type logInfo struct{ op string }

type ctxKey struct{}

func setLogOp(r *http.Request, op string) {
	if li, ok := r.Context().Value(ctxKey{}).(*logInfo); ok && len(op) <= 32 {
		li.op = op
	}
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		li := &logInfo{}
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r.WithContext(context.WithValue(r.Context(), ctxKey{}, li)))
		op := ""
		if li.op != "" {
			op = " op=" + li.op
		}
		log.Printf("%s %s%s status=%d bytes_in=%d dur=%s", r.Method, r.URL.Path, op, rec.status, r.ContentLength, time.Since(start).Round(time.Millisecond))
	})
}
