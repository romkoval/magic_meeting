#!/usr/bin/env bash
# End-to-end check of a deployed proxy: health, Whisper via Groq, and one LLM call.
# Usage: ./deploy/smoke.sh https://mm.example.de <client-token> <audio.m4a>
# The audio is yours and goes to Groq like any recording; the output stays in your terminal.
set -euo pipefail
base="${1:?usage: smoke.sh BASE_URL TOKEN AUDIO}"; token="${2:?token}"; audio="${3:?audio file}"
base="${base%/}"
device="smoke-$(hostname)"
auth=(-H "Authorization: Bearer $token" -H "X-Device-ID: $device")

echo "1/3 health"
curl -fsS "$base/healthz"; echo

echo "2/3 transcribe (Groq Whisper from the VPS IP)"
out=$(curl -sS -w '\n%{http_code} %{time_total}' "${auth[@]}" -F "file=@$audio" "$base/v1/transcribe")
status=$(tail -1 <<<"$out")
body=$(sed '$d' <<<"$out")
echo "   HTTP/time: $status"
[[ $status == 200* ]] || { echo "   body: $body"; exit 1; }
text=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["text"]); print("   language:", d.get("language"), "duration:", d.get("duration"), "segments:", len(d.get("segments") or []), file=sys.stderr)' <<<"$body")
echo "   text: ${text:0:300}"

echo "3/3 summarize (LLM)"
payload=$(python3 -c 'import json,sys; print(json.dumps({"op":"summarize","input":{"transcript":sys.argv[1],"ui_language":"ru"}}))' "$text")
out=$(curl -sS -w '\n%{http_code} %{time_total}' "${auth[@]}" -H 'Content-Type: application/json' -d "$payload" "$base/v1/llm")
status=$(tail -1 <<<"$out")
echo "   HTTP/time: $status"
sed '$d' <<<"$out" | head -c 600; echo
[[ $status == 200* ]] || exit 1
echo "OK"
