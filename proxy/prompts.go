package main

import (
	"fmt"
	"strings"
)

// All prompts live on the proxy so they can change without an App Store release.
// The client sends only the operation name and its data.

const commonRules = `General rules:
- Use only information present in the provided material. Never invent facts, decisions, deadlines, names, numbers or participants.
- If the material contains nothing for a section, write "not discussed" translated into the output language (in Russian: «не обсуждалось»).
- The transcript may contain misrecognized names and terms. When a word clearly refers to a glossary entry, spell it exactly as in the glossary.
- %s`

func languageRule(in LLMInput) string {
	lang := languageName(in.Language)
	ui := languageName(in.UILanguage)
	if ui == "" {
		ui = "English"
	}
	if lang != "" {
		return fmt.Sprintf("Write the output in %s, the language of the transcript.", lang)
	}
	return fmt.Sprintf("Write the output in the language of the transcript. If it cannot be determined, write in %s.", ui)
}

func languageName(code string) string {
	switch strings.ToLower(strings.TrimSpace(code)) {
	case "":
		return ""
	case "ru", "russian":
		return "Russian"
	case "en", "english":
		return "English"
	default:
		return code
	}
}

func system(in LLMInput, task string) string {
	return task + "\n\n" + fmt.Sprintf(commonRules, languageRule(in))
}

func section(title, body string) string {
	return "<<<" + title + ">>>\n" + strings.TrimSpace(body) + "\n<<<end " + title + ">>>\n\n"
}

func glossarySection(g []string) string {
	var terms []string
	for _, t := range g {
		if t = strings.TrimSpace(t); t != "" {
			terms = append(terms, t)
		}
	}
	if len(terms) == 0 {
		return ""
	}
	return section("glossary", strings.Join(terms, "\n"))
}

func buildSummarize(in LLMInput) (string, string) {
	sys := system(in, `You summarize meeting transcripts.
Return a JSON object with exactly two string fields:
- "title": a one-line description of the meeting for a history list, at most 60 characters, no trailing period;
- "summary": a concise summary as a short bulleted list ("- " per line), 3 to 7 bullets, covering the main topics, decisions and agreed tasks.`)
	user := glossarySection(in.Glossary) + section("transcript", in.Transcript)
	return sys, user
}

func buildProtocol(in LLMInput) (string, string) {
	sys := system(in, `You write meeting minutes strictly following the user's template.
The template is Markdown with placeholders in curly braces describing what to put there. Keep the template's headings and order, replace every placeholder with content from the meeting, and drop the braces.
Put the user's highlights into the "Key points" section (or its equivalent in the template's language), verbatim or very close to the text. If the template has no such section, add one after the discussion section.
Return only the finished minutes in Markdown, without code fences or commentary.`)
	var hl strings.Builder
	for _, h := range in.Highlights {
		if h = strings.TrimSpace(h); h != "" {
			hl.WriteString("- " + h + "\n")
		}
	}
	user := section("template", in.Template) +
		section("meeting date", in.Date) +
		section("meeting duration", in.Duration) +
		glossarySection(in.Glossary) +
		section("highlights", hl.String()) +
		section("summary", in.Summary) +
		section("transcript", in.Transcript)
	return sys, user
}

func buildEditTranscript(in LLMInput) (string, string) {
	sys := system(in, `You apply a user's spoken editing command to a meeting transcript by returning point replacements. Never rewrite the whole transcript.
Return a JSON object: {"replacements": [{"find": "...", "replace": "...", "all": true|false}]}
- "find" must be an exact substring of the transcript, long enough to be unambiguous when "all" is false.
- "all": true replaces every occurrence (e.g. "replace X with Y everywhere"), false replaces only the first occurrence of "find".
- To delete text, use an empty "replace".
- If the command cannot be applied, return {"replacements": []}.
The command itself was produced by speech recognition, so interpret obvious misrecognitions sensibly.`)
	user := glossarySection(in.Glossary) + section("command", in.Command) + section("transcript", in.Transcript)
	return sys, user
}

func buildEditText(in LLMInput) (string, string) {
	sys := system(in, `You apply a user's spoken editing command to a meeting summary or meeting minutes.
Change only what the command asks for and keep everything else, including formatting, exactly as it is.
Return only the full resulting text, without code fences or commentary.
The command itself was produced by speech recognition, so interpret obvious misrecognitions sensibly.`)
	user := glossarySection(in.Glossary) + section("command", in.Command) + section("text", in.Text)
	return sys, user
}

func buildHighlight(in LLMInput) (string, string) {
	sys := system(in, `The user asks to mark a moment of the meeting transcript as a highlight.
Find the passage the command refers to and return a JSON object {"quote": "..."} where "quote" is copied exactly, character for character, from the transcript: one to three sentences.
If nothing matches, return {"quote": ""}.`)
	user := section("command", in.Command) + section("transcript", in.Transcript)
	return sys, user
}

func buildPickTemplate(in LLMInput) (string, string) {
	sys := `The user asks for meeting minutes using one of their templates. Match the template name mentioned in the command against the list.
Return a JSON object {"id": "<id>"} when exactly one template clearly matches.
Return {"id": null, "candidates": ["<id>", ...]} when several templates could match or none matches clearly; list plausible ids, possibly an empty list.
The command was produced by speech recognition, so tolerate misrecognitions, word forms and translations.`
	var list strings.Builder
	for _, t := range in.Templates {
		list.WriteString(t.ID + ": " + t.Name + "\n")
	}
	user := section("command", in.Command) + section("templates", list.String())
	return sys, user
}

func buildDraftTemplate(in LLMInput) (string, string) {
	lang := languageName(in.UILanguage)
	if lang == "" {
		lang = "English"
	}
	sys := fmt.Sprintf(`You create a meeting minutes template from the user's spoken description.
The template is Markdown: a level-1 heading with the meeting topic, a few metadata lines, and level-2 section headings in the order the user wants.
Under each heading put a placeholder in curly braces describing what goes there, e.g. "{decisions made, numbered}". Tables are allowed for tasks.
Write the template in the language of the description; if it is unclear, in %s.
Return only the template, without code fences or commentary.`, lang)
	user := section("description", in.Description)
	return sys, user
}
