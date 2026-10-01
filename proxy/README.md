# Magic Meeting proxy

The only backend the iOS app talks to. It forwards audio to Groq Whisper and runs
LLM operations whose prompts live here (TZ §5, §7), so prompts can change
without an App Store release. Audio and texts pass through in memory: nothing is
written to disk, a database or logs. The Groq key lives only in the service's
environment.

Go 1.24, standard library only.

## API

All `/v1/*` requests need an `X-Device-ID` header (per-device rate limit) and,
if `CLIENT_TOKENS` is set, `Authorization: Bearer <token>`.

### `POST /v1/transcribe`

`multipart/form-data`:

| field | |
|---|---|
| `file` | audio chunk (m4a), up to `MAX_UPLOAD_MB` |
| `glossary` | optional, one term per line; goes to the Whisper `prompt` |
| `language` | optional ISO-639-1 code; auto-detected when empty |

Response:

```json
{"text": "...", "language": "russian", "duration": 612.4,
 "segments": [{"start": 0.0, "end": 4.2, "text": "..."}]}
```

Segment times are seconds from the start of the uploaded file; empty segments are dropped.

### `POST /v1/llm`

```json
{"op": "summarize", "input": {"transcript": "...", "glossary": ["..."], "language": "ru", "ui_language": "en"}}
```

Response: `{"op": "summarize", "result": {...}}`

| op | required input | result |
|---|---|---|
| `summarize` | `transcript` | `{title, summary}` (title ≤ 60 chars) |
| `protocol` | `transcript`, `template` (+ `summary`, `highlights`, `date`, `duration`) | `{text}` Markdown |
| `edit_transcript` | `command`, `transcript` | `{replacements: [{find, replace, all}]}` — only applicable ones |
| `edit_text` | `command`, `text` | `{text}` |
| `highlight` | `command`, `transcript` | `{quote}` (empty if not found) |
| `pick_template` | `command`, `templates: [{id, name}]` | `{id}` or `{id: null, candidates: [...]}` |
| `draft_template` | `description` | `{text}` Markdown template |

Optional in every op: `glossary`, `language` (detected transcript language),
`ui_language` (fallback output language).

Errors: `{"error": "..."}` with 400 / 401 / 413 / 429 / 502 / 503 (Groq busy,
`Retry-After` set) / 504.

## Run locally

```sh
GROQ_API_KEY=gsk_... go run .
go test ./...
```

## Deploy (Ubuntu VPS)

1. Install Caddy, put `deploy/Caddyfile` into `/etc/caddy/` with the real domain.
2. Create `/etc/magic-meeting/proxy.env` from `deploy/proxy.env.example`, `chmod 600`.
3. `./deploy/deploy.sh user@host` — builds, installs the systemd unit and checks `/healthz`.

PostgreSQL (accounts and minute counters) arrives with stage 8, Sign in with
Apple and subscriptions.
