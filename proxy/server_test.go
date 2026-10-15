package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

type fakeGroq struct {
	lastForm  map[string]string
	lastFile  []byte
	lastChat  chatRequest
	chatReply string
	status    int
}

func (f *fakeGroq) server(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer groq-key" {
			t.Errorf("missing groq key")
		}
		if f.status != 0 {
			w.WriteHeader(f.status)
			return
		}
		switch r.URL.Path {
		case "/audio/transcriptions":
			if err := r.ParseMultipartForm(1 << 20); err != nil {
				t.Fatal(err)
			}
			f.lastForm = map[string]string{}
			for k, v := range r.MultipartForm.Value {
				f.lastForm[k] = v[0]
			}
			file, _, _ := r.FormFile("file")
			f.lastFile, _ = io.ReadAll(file)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"text": " Привет, мир. ", "language": "russian", "duration": 12.5,
				"segments": []any{
					map[string]any{"id": 0, "start": 0.0, "end": 1.2, "text": " Привет,", "no_speech_prob": 0.01},
					map[string]any{"id": 1, "start": 1.2, "end": 2.0, "text": "  "},
					map[string]any{"id": 2, "start": 2.0, "end": 3.4, "text": " мир."},
				},
			})
		case "/chat/completions":
			_ = json.NewDecoder(r.Body).Decode(&f.lastChat)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"choices": []any{map[string]any{"message": map[string]string{"role": "assistant", "content": f.chatReply}}},
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
}

func newTestServer(t *testing.T, f *fakeGroq, tokens ...string) (*Server, *httptest.Server) {
	t.Helper()
	up := f.server(t)
	t.Cleanup(up.Close)
	cfg := Config{
		GroqAPIKey: "groq-key", GroqBaseURL: up.URL, STTModel: "whisper-large-v3", LLMModel: "test-llm",
		ClientTokens: tokens, RateLimitPerMin: 100, MaxUploadBytes: 1 << 20, MaxLLMBodyBytes: 1 << 20,
		UpstreamTimeout: 5 * time.Second,
	}
	s := NewServer(cfg, NewGroq(cfg))
	ts := httptest.NewServer(s.Handler())
	t.Cleanup(ts.Close)
	return s, ts
}

func transcribeRequest(t *testing.T, url string, audio []byte, fields map[string]string) *http.Request {
	t.Helper()
	var body bytes.Buffer
	w := multipart.NewWriter(&body)
	fw, _ := w.CreateFormFile("file", "segment.m4a")
	_, _ = fw.Write(audio)
	for k, v := range fields {
		_ = w.WriteField(k, v)
	}
	_ = w.Close()
	req, _ := http.NewRequest(http.MethodPost, url+"/v1/transcribe", &body)
	req.Header.Set("Content-Type", w.FormDataContentType())
	req.Header.Set("X-Device-ID", "device-1")
	return req
}

func TestTranscribeForwardsAudioAndGlossary(t *testing.T) {
	f := &fakeGroq{}
	_, ts := newTestServer(t, f)
	req := transcribeRequest(t, ts.URL, []byte("AUDIO"), map[string]string{"glossary": "Курбатский\n\nГрук", "language": "RU"})
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d", resp.StatusCode)
	}
	var got TranscribeResult
	_ = json.NewDecoder(resp.Body).Decode(&got)
	if got.Text != "Привет, мир." || got.Duration != 12.5 || got.Language != "russian" {
		t.Fatalf("unexpected result %+v", got)
	}
	if len(got.Segments) != 2 || got.Segments[1] != (TranscriptSegment{Start: 2.0, End: 3.4, Text: "мир."}) {
		t.Fatalf("unexpected segments %+v", got.Segments)
	}
	if string(f.lastFile) != "AUDIO" {
		t.Fatalf("audio not forwarded")
	}
	want := map[string]string{"model": "whisper-large-v3", "prompt": "Курбатский, Грук.", "language": "ru", "response_format": "verbose_json"}
	for k, v := range want {
		if f.lastForm[k] != v {
			t.Errorf("%s = %q, want %q", k, f.lastForm[k], v)
		}
	}
}

func TestAuthAndDeviceID(t *testing.T) {
	f := &fakeGroq{}
	_, ts := newTestServer(t, f, "pilot-token")

	req := transcribeRequest(t, ts.URL, []byte("A"), nil)
	resp, _ := http.DefaultClient.Do(req)
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", resp.StatusCode)
	}

	req = transcribeRequest(t, ts.URL, []byte("A"), nil)
	req.Header.Set("Authorization", "Bearer pilot-token")
	req.Header.Del("X-Device-ID")
	resp, _ = http.DefaultClient.Do(req)
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("want 400 without device id, got %d", resp.StatusCode)
	}

	req = transcribeRequest(t, ts.URL, []byte("A"), nil)
	req.Header.Set("Authorization", "Bearer pilot-token")
	resp, _ = http.DefaultClient.Do(req)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("want 200, got %d", resp.StatusCode)
	}
}

func postLLM(t *testing.T, url string, body any) (int, map[string]json.RawMessage) {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, url+"/v1/llm", bytes.NewReader(b))
	req.Header.Set("X-Device-ID", "device-1")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]json.RawMessage
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func TestSummarize(t *testing.T) {
	f := &fakeGroq{chatReply: `{"title":"Созвон с поставщиком по срокам поставки оборудования на новый склад в Твери.","summary":"- Сроки сдвинуты"}`}
	_, ts := newTestServer(t, f)
	status, out := postLLM(t, ts.URL, LLMRequest{Op: "summarize", Input: LLMInput{Transcript: "текст", Language: "russian", Glossary: []string{"Курбатский"}}})
	if status != http.StatusOK {
		t.Fatalf("status %d: %s", status, out["error"])
	}
	var r summarizeResult
	_ = json.Unmarshal(out["result"], &r)
	if n := len([]rune(r.Title)); n > 60 || r.Summary != "- Сроки сдвинуты" {
		t.Fatalf("bad result %+v (title %d runes)", r, n)
	}
	if f.lastChat.ResponseFormat == nil || f.lastChat.Model != "test-llm" {
		t.Fatalf("expected json mode with configured model: %+v", f.lastChat)
	}
	if !strings.Contains(f.lastChat.Messages[0].Content, "Russian") || !strings.Contains(f.lastChat.Messages[1].Content, "Курбатский") {
		t.Fatalf("prompt misses language or glossary")
	}
}

func TestEditTranscriptFiltersInapplicableReplacements(t *testing.T) {
	f := &fakeGroq{chatReply: "```json\n" + `{"replacements":[{"find":"Курбацкий","replace":"Курбатский","all":true},{"find":"нет такого","replace":"x"},{"find":"","replace":"y"}]}` + "\n```"}
	_, ts := newTestServer(t, f)
	status, out := postLLM(t, ts.URL, LLMRequest{Op: "edit_transcript", Input: LLMInput{Command: "замени", Transcript: "Курбацкий сказал. Курбацкий ушёл."}})
	if status != http.StatusOK {
		t.Fatalf("status %d", status)
	}
	var r replacementsResult
	_ = json.Unmarshal(out["result"], &r)
	if len(r.Replacements) != 1 || r.Replacements[0].Replace != "Курбатский" || !r.Replacements[0].All {
		t.Fatalf("unexpected %+v", r)
	}
}

func TestPickTemplate(t *testing.T) {
	templates := []TemplateRef{{ID: "a", Name: "Встреча с заказчиком"}, {ID: "b", Name: "Планёрка"}}
	cases := []struct {
		reply, wantID  string
		wantCandidates int
	}{
		{`{"id":"a"}`, "a", 0},
		{`{"id":"zzz","candidates":["a","b","zzz"]}`, "", 2},
		{`{"id":null,"candidates":["b"]}`, "b", 0},
	}
	for _, c := range cases {
		f := &fakeGroq{chatReply: c.reply}
		_, ts := newTestServer(t, f)
		_, out := postLLM(t, ts.URL, LLMRequest{Op: "pick_template", Input: LLMInput{Command: "по шаблону заказчика", Templates: templates}})
		var r pickTemplateResult
		_ = json.Unmarshal(out["result"], &r)
		id := ""
		if r.ID != nil {
			id = *r.ID
		}
		if id != c.wantID || len(r.Candidates) != c.wantCandidates {
			t.Errorf("reply %s: got id=%q candidates=%v", c.reply, id, r.Candidates)
		}
	}
}

func TestLLMValidationAndUpstreamErrors(t *testing.T) {
	f := &fakeGroq{}
	_, ts := newTestServer(t, f)
	if status, _ := postLLM(t, ts.URL, LLMRequest{Op: "nope"}); status != http.StatusBadRequest {
		t.Fatalf("unknown op: %d", status)
	}
	if status, _ := postLLM(t, ts.URL, LLMRequest{Op: "protocol", Input: LLMInput{Transcript: "x"}}); status != http.StatusBadRequest {
		t.Fatalf("missing template: %d", status)
	}
	f.status = http.StatusTooManyRequests
	if status, _ := postLLM(t, ts.URL, LLMRequest{Op: "edit_text", Input: LLMInput{Text: "x", Command: "y"}}); status != http.StatusServiceUnavailable {
		t.Fatalf("groq 429: %d", status)
	}
}

func TestRateLimiter(t *testing.T) {
	now := time.Unix(0, 0)
	l := NewRateLimiter(2)
	l.now = func() time.Time { return now }
	if !l.Allow("d") || !l.Allow("d") || l.Allow("d") {
		t.Fatal("bucket should hold exactly 2 requests")
	}
	if !l.Allow("other") {
		t.Fatal("buckets must be per device")
	}
	now = now.Add(30 * time.Second)
	if !l.Allow("d") || l.Allow("d") {
		t.Fatal("expected one token after half a minute")
	}
}

func TestStripFences(t *testing.T) {
	if got := stripFences("```markdown\n# Протокол\n```"); got != "# Протокол" {
		t.Fatalf("got %q", got)
	}
	if got := stripFences("  plain  "); got != "plain" {
		t.Fatalf("got %q", got)
	}
}

func TestParseReplacementsBoundsModelOutput(t *testing.T) {
	transcript := strings.Repeat("a", 3000) + " Курбацкий ушёл."
	rep := func(find, replace string, all bool) Replacement {
		return Replacement{Find: find, Replace: replace, All: all}
	}
	many := make([]Replacement, 0, 60)
	for i := 0; i < 60; i++ {
		many = append(many, rep(strings.Repeat("a", i+1), "b", false))
	}
	cases := []struct {
		name string
		in   []Replacement
		want []Replacement
	}{
		{"exact duplicates dropped", []Replacement{rep("Курбацкий", "Курбатский", true), rep("Курбацкий", "Курбатский", true)},
			[]Replacement{rep("Курбацкий", "Курбатский", true)}},
		{"same find with different all or replace kept", []Replacement{rep("Курбацкий", "Курбатский", true), rep("Курбацкий", "Курбатский", false), rep("Курбацкий", "Другой", true)},
			[]Replacement{rep("Курбацкий", "Курбатский", true), rep("Курбацкий", "Курбатский", false), rep("Курбацкий", "Другой", true)}},
		{"find at the limit kept, over it dropped", []Replacement{rep(strings.Repeat("a", maxReplacementBytes), "x", false), rep(strings.Repeat("a", maxReplacementBytes+1), "x", false)},
			[]Replacement{rep(strings.Repeat("a", maxReplacementBytes), "x", false)}},
		{"replace over the limit dropped", []Replacement{rep("Курбацкий", strings.Repeat("x", maxReplacementBytes+1), false), rep("ушёл", strings.Repeat("x", maxReplacementBytes), false)},
			[]Replacement{rep("ушёл", strings.Repeat("x", maxReplacementBytes), false)}},
		{"capped after filtering", append([]Replacement{rep("нет такого", "x", false)}, many...), many[:maxReplacements]},
	}
	for _, c := range cases {
		raw, _ := json.Marshal(replacementsResult{Replacements: c.in})
		got, err := parseReplacements(string(raw), LLMInput{Transcript: transcript})
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		reps := got.(replacementsResult).Replacements
		if len(reps) != len(c.want) {
			t.Errorf("%s: got %d replacements, want %d", c.name, len(reps), len(c.want))
			continue
		}
		for i := range reps {
			if reps[i] != c.want[i] {
				t.Errorf("%s: replacement %d differs", c.name, i)
			}
		}
	}
}

func TestCommandLengthLimit(t *testing.T) {
	cases := []struct {
		name    string
		op      string
		command string
		want    int
	}{
		{"edit_transcript at limit", "edit_transcript", strings.Repeat("a", maxCommandBytes), http.StatusOK},
		{"edit_transcript over limit", "edit_transcript", strings.Repeat("a", maxCommandBytes+1), http.StatusBadRequest},
		{"edit_text at limit", "edit_text", strings.Repeat("a", maxCommandBytes), http.StatusOK},
		{"edit_text over limit", "edit_text", strings.Repeat("a", maxCommandBytes+1), http.StatusBadRequest},
		{"multibyte counts bytes", "edit_text", strings.Repeat("я", maxCommandBytes/2+1), http.StatusBadRequest},
	}
	for _, c := range cases {
		f := &fakeGroq{chatReply: `{"replacements":[]}`}
		_, ts := newTestServer(t, f)
		status, _ := postLLM(t, ts.URL, LLMRequest{Op: c.op, Input: LLMInput{Text: "текст", Transcript: "текст", Command: c.command}})
		if status != c.want {
			t.Errorf("%s: status %d, want %d", c.name, status, c.want)
		}
	}
}

func TestMaxTokensPerOperation(t *testing.T) {
	in := LLMInput{
		Transcript: "текст", Text: "текст", Command: "команда", Template: "# T", Description: "описание",
		Templates: []TemplateRef{{ID: "a", Name: "A"}},
	}
	cases := []struct {
		op   string
		want int
	}{
		{"edit_transcript", 4096}, {"highlight", 4096}, {"pick_template", 4096}, {"summarize", 4096},
		{"protocol", 0}, {"edit_text", 0}, {"draft_template", 0},
	}
	if len(cases) != len(operations) {
		t.Fatalf("test covers %d ops, server has %d", len(cases), len(operations))
	}
	for _, c := range cases {
		f := &fakeGroq{chatReply: `{"title":"t","summary":"s","replacements":[],"quote":"","id":"a"}`}
		_, ts := newTestServer(t, f)
		if status, _ := postLLM(t, ts.URL, LLMRequest{Op: c.op, Input: in}); status != http.StatusOK {
			t.Errorf("%s: status %d", c.op, status)
			continue
		}
		if f.lastChat.MaxTokens != c.want {
			t.Errorf("%s: max_tokens = %d, want %d", c.op, f.lastChat.MaxTokens, c.want)
		}
	}
}

func TestRunLLMPassesMaxTokensToChat(t *testing.T) {
	var got int
	chat := func(_ context.Context, _, _ string, _ bool, maxTokens int) (string, error) {
		got = maxTokens
		return `{"quote":"x"}`, nil
	}
	if _, err := RunLLM(context.Background(), chat, LLMRequest{Op: "highlight", Input: LLMInput{Transcript: "x", Command: "y"}}); err != nil {
		t.Fatal(err)
	}
	if got != 4096 {
		t.Fatalf("maxTokens = %d", got)
	}
}

func TestPromptsTreatSectionsAsData(t *testing.T) {
	in := LLMInput{
		Transcript: "t", Text: "t", Command: "c", Template: "# T", Description: "d", Highlights: []string{"h"},
		Templates: []TemplateRef{{ID: "a", Name: "A"}},
	}
	for op, o := range operations {
		sys, _ := o.build(in)
		if !strings.Contains(sys, dataRule) {
			t.Errorf("%s: system prompt lacks the data-not-instructions rule", op)
		}
	}
}

func TestLoadConfigRequiresClientTokens(t *testing.T) {
	cases := []struct {
		name, tokens, allow string
		wantErr             bool
		wantTokens          int
	}{
		{"empty tokens rejected", "", "", true, 0},
		{"blank tokens rejected", " , ", "", true, 0},
		{"allow no auth must be exactly 1", "", "true", true, 0},
		{"tokens accepted", "a, b", "", false, 2},
		{"explicit no auth", "", "1", false, 0},
	}
	for _, c := range cases {
		t.Setenv("GROQ_API_KEY", "groq-key")
		t.Setenv("CLIENT_TOKENS", c.tokens)
		t.Setenv("ALLOW_NO_AUTH", c.allow)
		cfg, err := LoadConfig()
		if (err != nil) != c.wantErr || len(cfg.ClientTokens) != c.wantTokens {
			t.Errorf("%s: err=%v tokens=%d", c.name, err, len(cfg.ClientTokens))
		}
	}
}

func TestRequestLogDoesNotEchoClientControlledText(t *testing.T) {
	var buf bytes.Buffer
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	f := &fakeGroq{chatReply: `{"quote":"x"}`}
	_, ts := newTestServer(t, f)

	cases := []struct {
		name   string
		op     string
		path   string
		want   []string
		reject []string
	}{
		{"known op", "highlight", "/v1/llm", []string{"op=highlight"}, nil},
		{"unknown op", "evil\nINJECTED line", "/v1/llm", []string{"op=unknown"}, []string{"INJECTED"}},
		{"path is quoted", "", "/v1/x%0AINJECTED%20line", []string{`"/v1/x\nINJECTED line"`}, []string{"\nINJECTED"}},
	}
	for _, c := range cases {
		buf.Reset()
		var req *http.Request
		if c.op != "" {
			b, _ := json.Marshal(LLMRequest{Op: c.op, Input: LLMInput{Transcript: "x", Command: "y"}})
			req, _ = http.NewRequest(http.MethodPost, ts.URL+c.path, bytes.NewReader(b))
			req.Header.Set("X-Device-ID", "device-1")
		} else {
			req, _ = http.NewRequest(http.MethodGet, ts.URL+c.path, nil)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		logged := buf.String()
		for _, w := range c.want {
			if !strings.Contains(logged, w) {
				t.Errorf("%s: log %q lacks %q", c.name, logged, w)
			}
		}
		for _, r := range c.reject {
			if strings.Contains(logged, r) {
				t.Errorf("%s: log %q contains %q", c.name, logged, r)
			}
		}
	}
}
