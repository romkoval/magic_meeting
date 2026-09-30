# Magic Meeting

iOS app that records meetings and turns them into a punctuated transcript,
summary and minutes from a template, all editable by voice. The spec is the
TZ document "iOS-приложение для записи и протоколирования встреч".

```
ios/     SwiftUI app, iOS 17+, Swift 6, system frameworks only
proxy/   Go service on the VPS: /v1/transcribe and /v1/llm, Groq key and prompts live here
```

## Build the app

```sh
cd ios
cp Config/Local.xcconfig.example Config/Local.xcconfig   # proxy host, team id
brew install xcodegen && xcodegen                         # generates MagicMeeting.xcodeproj
open MagicMeeting.xcodeproj
```

## Run the proxy

See [proxy/README.md](proxy/README.md). Locally: `cd proxy && GROQ_API_KEY=... go run .`

## Progress against the work plan (TZ §11)

| # | Stage | State |
|---|---|---|
| 1 | Proxy: transcribe and llm endpoints, env key, systemd, deploy | done; PostgreSQL arrives with stage 8 |
| 2 | Recording with pause, background, interruptions; SwiftData; sending and showing the transcript | done |
| 3 | History, recording card with tabs, copy and share | done |
| 4 | Voice edit mode: edit_transcript / edit_text, change highlighting, undo | proxy side done; `EditStep` history already recorded on manual edits |
| 5 | Highlights, minutes, default template | proxy side done; models in place |
| 6 | Template library, voice drafting and picking | proxy side done |
| 7 | Glossary, append, long recording chunking | append and 10-minute chunking with overlap done; glossary is sent, settings UI pending |
| 8 | Sign in with Apple, StoreKit 2, minute accounting, paywall | not started |
| 9 | Onboarding consent, App Attest, privacy manifest, policy, TestFlight | consent screen and privacy manifest done; App Attest pending (pilot uses a bearer token) |
