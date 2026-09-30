// Command proxy is the only backend the Magic Meeting app talks to. It
// forwards audio to Groq Whisper and runs the LLM operations whose prompts
// live here. Meeting content passes through in memory and is never stored.
package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	cfg, err := LoadConfig()
	if err != nil {
		log.Fatal(err)
	}
	srv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           NewServer(cfg, NewGroq(cfg)).Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       2 * time.Minute,
		WriteTimeout:      cfg.UpstreamTimeout + 30*time.Second,
		IdleTimeout:       2 * time.Minute,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		log.Printf("listening on %s (stt=%s, llm=%s)", cfg.ListenAddr, cfg.STTModel, cfg.LLMModel)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()
	<-ctx.Done()

	shutdown, cancel := context.WithTimeout(context.Background(), cfg.UpstreamTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdown); err != nil {
		log.Printf("shutdown: %v", err)
	}
}
