# Magic Meeting

iOS app (SwiftUI, SwiftData, Swift 6) that records meetings and turns them into
transcript, summary and minutes, plus a Go proxy in front of Groq.
Spec: `docs/TZ.md`. Process: `docs/WORKFLOW.md`. Stage plans: `docs/plans/`.

## Layout

- `ios/` — app. `project.yml` is the XcodeGen spec; the `.xcodeproj` is generated, never committed.
- `ios/MagicMeeting/{App,Models,Services,Views,Support,Resources}`; tests in `ios/MagicMeetingTests`.
- `proxy/` — Go 1.24, standard library only. Prompts live in `proxy/prompts.go`.

## What runs where

- **Go**: `cd proxy && gofmt -l . && go vet ./... && go test -race ./...` runs locally.
- **Swift**: there is no Swift toolchain in the cloud container. `swift build`, `xcodebuild`
  and `swiftlint` are not available here. Swift is verified only by CI
  (`.github/workflows/ci.yml`, macos-26, latest Xcode 26, simulator unit tests).
  Reviewers read the code instead of building it; implementers write XCTest tests
  that CI runs.
- Pure logic goes into small types without UIKit/SwiftData dependencies so it can be unit tested.

## Conventions

- Swift 6 strict concurrency. Services are `@MainActor @Observable`; network code is
  `Sendable` structs. Closures handed to system APIs that call back on other queues are
  marked `@Sendable` explicitly.
- No third-party dependencies in the app or the proxy.
- Every user-facing string goes into `Resources/Localizable.xcstrings` with a Russian translation.
  Use English keys; `Text(someString)` for user content is verbatim.
- Meeting content (audio, transcripts, commands, model answers) is never logged or stored on the proxy.
- Comments explain why, not what. Match the density of the surrounding code.
- Commits: imperative subject, body explains why. One logical change per commit.
