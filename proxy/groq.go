package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"strings"
)

// whisperPromptMaxRunes keeps the glossary within Whisper's ~224 token prompt window.
const whisperPromptMaxRunes = 700

type Groq struct {
	baseURL  string
	apiKey   string
	sttModel string
	llmModel string
	http     *http.Client
}

func NewGroq(c Config) *Groq {
	return &Groq{
		baseURL:  c.GroqBaseURL,
		apiKey:   c.GroqAPIKey,
		sttModel: c.STTModel,
		llmModel: c.LLMModel,
		http:     &http.Client{Timeout: c.UpstreamTimeout},
	}
}

// UpstreamError carries Groq's status code but never its body, which may echo content.
type UpstreamError struct{ Status int }

func (e *UpstreamError) Error() string { return fmt.Sprintf("groq returned status %d", e.Status) }

type TranscribeResult struct {
	Text     string  `json:"text"`
	Language string  `json:"language"`
	Duration float64 `json:"duration"`
	// Segments carry Whisper's timestamps (seconds from the start of the
	// uploaded file). Speaker diarization will be aligned to them (TZ §12).
	Segments []TranscriptSegment `json:"segments"`
}

type TranscriptSegment struct {
	Start float64 `json:"start"`
	End   float64 `json:"end"`
	Text  string  `json:"text"`
}

func (g *Groq) Transcribe(ctx context.Context, fileName string, audio io.Reader, glossary []string, language string) (TranscribeResult, error) {
	var body bytes.Buffer
	w := multipart.NewWriter(&body)
	fw, err := w.CreateFormFile("file", fileName)
	if err != nil {
		return TranscribeResult{}, err
	}
	if _, err := io.Copy(fw, audio); err != nil {
		return TranscribeResult{}, err
	}
	_ = w.WriteField("model", g.sttModel)
	_ = w.WriteField("response_format", "verbose_json")
	_ = w.WriteField("temperature", "0")
	if p := whisperPrompt(glossary); p != "" {
		_ = w.WriteField("prompt", p)
	}
	if language != "" {
		_ = w.WriteField("language", language)
	}
	if err := w.Close(); err != nil {
		return TranscribeResult{}, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.baseURL+"/audio/transcriptions", &body)
	if err != nil {
		return TranscribeResult{}, err
	}
	req.Header.Set("Content-Type", w.FormDataContentType())
	var out TranscribeResult
	if err := g.do(req, &out); err != nil {
		return TranscribeResult{}, err
	}
	out.Text = strings.TrimSpace(out.Text)
	segments := make([]TranscriptSegment, 0, len(out.Segments))
	for _, seg := range out.Segments {
		if seg.Text = strings.TrimSpace(seg.Text); seg.Text != "" {
			segments = append(segments, seg)
		}
	}
	out.Segments = segments
	return out, nil
}

// whisperPrompt turns the user's glossary into a Whisper prompt. Whisper treats
// the prompt as preceding text, so a plain comma-separated list works best.
func whisperPrompt(glossary []string) string {
	var terms []string
	size := 0
	for _, t := range glossary {
		t = strings.TrimSpace(t)
		if t == "" {
			continue
		}
		n := len([]rune(t)) + 2
		if size+n > whisperPromptMaxRunes {
			break
		}
		size += n
		terms = append(terms, t)
	}
	if len(terms) == 0 {
		return ""
	}
	return strings.Join(terms, ", ") + "."
}

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type chatRequest struct {
	Model          string          `json:"model"`
	Messages       []chatMessage   `json:"messages"`
	Temperature    float64         `json:"temperature"`
	ResponseFormat *responseFormat `json:"response_format,omitempty"`
}

type responseFormat struct {
	Type string `json:"type"`
}

type chatResponse struct {
	Choices []struct {
		Message chatMessage `json:"message"`
	} `json:"choices"`
}

// Chat sends one system+user exchange and returns the assistant's text.
func (g *Groq) Chat(ctx context.Context, system, user string, jsonMode bool) (string, error) {
	cr := chatRequest{
		Model:       g.llmModel,
		Messages:    []chatMessage{{Role: "system", Content: system}, {Role: "user", Content: user}},
		Temperature: 0.2,
	}
	if jsonMode {
		cr.ResponseFormat = &responseFormat{Type: "json_object"}
	}
	payload, err := json.Marshal(cr)
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.baseURL+"/chat/completions", bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	var out chatResponse
	if err := g.do(req, &out); err != nil {
		return "", err
	}
	if len(out.Choices) == 0 {
		return "", fmt.Errorf("groq returned no choices")
	}
	return out.Choices[0].Message.Content, nil
}

func (g *Groq) do(req *http.Request, out any) error {
	req.Header.Set("Authorization", "Bearer "+g.apiKey)
	resp, err := g.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		_, _ = io.Copy(io.Discard, resp.Body)
		return &UpstreamError{Status: resp.StatusCode}
	}
	return json.NewDecoder(resp.Body).Decode(out)
}
