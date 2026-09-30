package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"
)

type TemplateRef struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type LLMInput struct {
	Transcript  string        `json:"transcript,omitempty"`
	Summary     string        `json:"summary,omitempty"`
	Text        string        `json:"text,omitempty"`
	Command     string        `json:"command,omitempty"`
	Highlights  []string      `json:"highlights,omitempty"`
	Template    string        `json:"template,omitempty"`
	Date        string        `json:"date,omitempty"`
	Duration    string        `json:"duration,omitempty"`
	Glossary    []string      `json:"glossary,omitempty"`
	Templates   []TemplateRef `json:"templates,omitempty"`
	Description string        `json:"description,omitempty"`
	Language    string        `json:"language,omitempty"`    // language detected by Whisper
	UILanguage  string        `json:"ui_language,omitempty"` // fallback when Language is empty
}

type LLMRequest struct {
	Op    string   `json:"op"`
	Input LLMInput `json:"input"`
}

// ErrBadInput marks client errors; its message is safe to return and contains no content.
type ErrBadInput struct{ msg string }

func (e ErrBadInput) Error() string { return e.msg }

func badInput(format string, a ...any) error { return ErrBadInput{fmt.Sprintf(format, a...)} }

// errBadModelOutput is returned when the LLM answers with something we cannot use.
var errBadModelOutput = errors.New("model returned malformed output")

type chatFunc func(ctx context.Context, system, user string, jsonMode bool) (string, error)

type operation struct {
	required func(LLMInput) error
	build    func(LLMInput) (string, string)
	jsonMode bool
	// parse converts the raw model answer into the result object sent to the client.
	parse func(raw string, in LLMInput) (any, error)
}

var operations = map[string]operation{
	"summarize": {
		required: need(func(in LLMInput) bool { return in.Transcript != "" }, "transcript"),
		build:    buildSummarize, jsonMode: true, parse: parseSummarize,
	},
	"protocol": {
		required: need(func(in LLMInput) bool { return in.Transcript != "" && in.Template != "" }, "transcript, template"),
		build:    buildProtocol, parse: parseText,
	},
	"edit_transcript": {
		required: need(func(in LLMInput) bool { return in.Transcript != "" && in.Command != "" }, "transcript, command"),
		build:    buildEditTranscript, jsonMode: true, parse: parseReplacements,
	},
	"edit_text": {
		required: need(func(in LLMInput) bool { return in.Text != "" && in.Command != "" }, "text, command"),
		build:    buildEditText, parse: parseText,
	},
	"highlight": {
		required: need(func(in LLMInput) bool { return in.Transcript != "" && in.Command != "" }, "transcript, command"),
		build:    buildHighlight, jsonMode: true, parse: parseHighlight,
	},
	"pick_template": {
		required: need(func(in LLMInput) bool { return in.Command != "" && len(in.Templates) > 0 }, "command, templates"),
		build:    buildPickTemplate, jsonMode: true, parse: parsePickTemplate,
	},
	"draft_template": {
		required: need(func(in LLMInput) bool { return in.Description != "" }, "description"),
		build:    buildDraftTemplate, parse: parseText,
	},
}

func need(ok func(LLMInput) bool, fields string) func(LLMInput) error {
	return func(in LLMInput) error {
		if !ok(in) {
			return badInput("required fields: %s", fields)
		}
		return nil
	}
}

func RunLLM(ctx context.Context, chat chatFunc, req LLMRequest) (any, error) {
	op, ok := operations[req.Op]
	if !ok {
		return nil, badInput("unknown op %q", req.Op)
	}
	if err := op.required(req.Input); err != nil {
		return nil, err
	}
	sys, user := op.build(req.Input)
	raw, err := chat(ctx, sys, user, op.jsonMode)
	if err != nil {
		return nil, err
	}
	return op.parse(raw, req.Input)
}

type textResult struct {
	Text string `json:"text"`
}

func parseText(raw string, _ LLMInput) (any, error) {
	t := stripFences(raw)
	if t == "" {
		return nil, errBadModelOutput
	}
	return textResult{Text: t}, nil
}

// stripFences removes a Markdown code fence the model may wrap its answer in.
func stripFences(s string) string {
	s = strings.TrimSpace(s)
	if !strings.HasPrefix(s, "```") || !strings.HasSuffix(s, "```") || len(s) < 6 {
		return s
	}
	s = strings.TrimSuffix(s, "```")
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[i+1:]
	} else {
		s = strings.TrimPrefix(s, "```")
	}
	return strings.TrimSpace(s)
}

type summarizeResult struct {
	Title   string `json:"title"`
	Summary string `json:"summary"`
}

func parseSummarize(raw string, _ LLMInput) (any, error) {
	var r summarizeResult
	if err := json.Unmarshal([]byte(stripFences(raw)), &r); err != nil {
		return nil, errBadModelOutput
	}
	r.Title = truncateRunes(strings.TrimSpace(strings.TrimRight(strings.TrimSpace(r.Title), ".")), 60)
	r.Summary = strings.TrimSpace(r.Summary)
	if r.Summary == "" {
		return nil, errBadModelOutput
	}
	return r, nil
}

func truncateRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return strings.TrimSpace(string(r[:n-1])) + "…"
}

type Replacement struct {
	Find    string `json:"find"`
	Replace string `json:"replace"`
	All     bool   `json:"all"`
}

type replacementsResult struct {
	Replacements []Replacement `json:"replacements"`
}

func parseReplacements(raw string, in LLMInput) (any, error) {
	var r replacementsResult
	if err := json.Unmarshal([]byte(stripFences(raw)), &r); err != nil {
		return nil, errBadModelOutput
	}
	// Keep only replacements that can actually be applied to the transcript.
	out := replacementsResult{Replacements: []Replacement{}}
	for _, rep := range r.Replacements {
		if rep.Find != "" && rep.Find != rep.Replace && strings.Contains(in.Transcript, rep.Find) {
			out.Replacements = append(out.Replacements, rep)
		}
	}
	return out, nil
}

type highlightResult struct {
	Quote string `json:"quote"`
}

func parseHighlight(raw string, _ LLMInput) (any, error) {
	var r highlightResult
	if err := json.Unmarshal([]byte(stripFences(raw)), &r); err != nil {
		return nil, errBadModelOutput
	}
	r.Quote = strings.TrimSpace(r.Quote)
	return r, nil
}

type pickTemplateResult struct {
	ID         *string  `json:"id"`
	Candidates []string `json:"candidates"`
}

func parsePickTemplate(raw string, in LLMInput) (any, error) {
	var r pickTemplateResult
	if err := json.Unmarshal([]byte(stripFences(raw)), &r); err != nil {
		return nil, errBadModelOutput
	}
	known := map[string]bool{}
	for _, t := range in.Templates {
		known[t.ID] = true
	}
	out := pickTemplateResult{Candidates: []string{}}
	if r.ID != nil && known[*r.ID] {
		out.ID = r.ID
		return out, nil
	}
	for _, id := range r.Candidates {
		if known[id] {
			out.Candidates = append(out.Candidates, id)
		}
	}
	if len(out.Candidates) == 1 {
		out.ID, out.Candidates = &out.Candidates[0], []string{}
	}
	return out, nil
}
