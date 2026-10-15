# Implementation Plan: Stage 4 — Voice Edit Mode

## 1. Overview and requirements

When the user opens edit mode on a recording card, they speak a command. The app records it, sends it to `POST /v1/transcribe`, and then sends it to `POST /v1/llm` together with the text of the open tab:
- **Transcript** uses `edit_transcript`. The LLM returns `{find, replace, all}` replacements, and the app applies them locally.
- **Summary and minutes** use `edit_text`. The LLM returns the whole new text.

After an edit, the changed fragments are highlighted. «Отменить» (Undo) walks back through up to 20 `EditStep`s per recording.

Requirements (TZ §2, §3.6, §4, §6, §9):
- Edit mode is a state of `RecordingDetailView`, not a separate screen. «Править» becomes a large hold-or-tap button, and a status line «Слушаю / Применяю» appears above the text.
- The target is the open tab: `.transcript`, `.summary` or `.protocolText`.
- Transcript edits only apply replacements. They never rewrite the whole text, and they set `isTranscriptEdited = true`.
- Every applied edit creates an `EditStep` through `EditHistory.record(..., command:)`. Undo can go back several steps and only touches the open tab's target.
- Manual editing stays as it is now.
- Target latency is 5 s or less. Voice edits fail fast instead of retrying for long.
- Errors:
  - no consent → show the existing `ConsentView` sheet;
  - offline or server error → readable message, text not changed;
  - empty command → "didn't catch that";
  - zero applicable changes → "nothing to change", and no `EditStep` is created.
- Out of scope: the `highlight` op, protocol generation and templates.

**Proxy: no changes.** The proxy already handles both ops:
- `edit_transcript` and `edit_text` exist, including required-field checks, prompts and JSON mode.
- `parseReplacements` drops replacements with an empty `find`, with `find == replace`, or whose `find` is not in the transcript, and always returns `{"replacements": []}` rather than null.
- `parseText` strips code fences and rejects empty output.
- `TestEditTranscriptFiltersInapplicableReplacements` covers the filtering.

Because the proxy does not change, `go-reviewer` is not needed.

## 2. Design

### 2.1 Pure logic (no SwiftUI/SwiftData/AVFoundation; `import Foundation` only)

**`ios/MagicMeeting/Support/TextReplacement.swift`**
```swift
/// One point replacement from `edit_transcript`; mirrors proxy `Replacement`.
struct TextReplacement: Codable, Sendable, Equatable {
    let find: String
    let replace: String
    let all: Bool
}

struct ReplacementOutcome: Equatable {
    /// Text after all replacements.
    let text: String
    /// Ranges in `text` covering inserted replacement text: sorted, non-empty,
    /// non-overlapping, adjacent/overlapping ranges merged. Pure deletions leave no range.
    let changedRanges: [Range<String.Index>]
    /// Number of occurrences actually replaced.
    let appliedCount: Int
}

enum ReplacementApplier {
    static func apply(_ replacements: [TextReplacement], to text: String) -> ReplacementOutcome
}
```
Contract:
- **Order.** Replacements apply sequentially, in array order, each one to the result of the previous one.
- **Skipped replacements.** Skip any replacement with an empty `find` or with `find == replace`.
- **Matching.** Matches are computed once per replacement on the current text, so a `replace` that contains its own `find` (`"a"→"aa"`) cannot loop.
  - `all == false`: use `firstRange(of: find)`.
  - `all == true`: use `ranges(of: find)` (stdlib, non-overlapping, left to right).
- **Applying matches.** Apply one replacement's matches from last to first.
- **Use UTF-8 offsets, not stored indices.** Mutating a String invalidates its indices, so keep working positions as UTF-8 offsets and rebuild `String.Index` from them.
- **Mapping existing marks.** For an edit that replaces `[lo, hi)` with text of length `n` (offsets), let `delta = n - (hi - lo)`. Map each existing mark `m` like this:
  - if `m.upper <= lo`: keep `m`;
  - else if `m.lower >= hi`: shift `m` by `delta`;
  - else: `[min(m.lower, lo), m.upper >= hi ? m.upper + delta : lo + n)`.
  
  Then add the new mark `[lo, lo + n)`.
- **Final ranges.** Drop empty marks, sort, merge overlapping or adjacent marks, and convert to `Range<String.Index>` in the final text.
- **Nothing found.** A `find` that is no longer found because an earlier replacement consumed it is skipped silently.

**`ios/MagicMeeting/Support/WordDiff.swift`**
```swift
enum WordDiff {
    /// Above this many tokens on either side no ranges are returned (keeps the main actor responsive).
    static let maxTokens = 3_000
    /// Ranges in `new` covering words inserted or changed relative to `old`.
    static func changedRanges(from old: String, to new: String) -> [Range<String.Index>]
}
```
- **Tokens.** A token is a maximal run of non-whitespace `Character`s (`!$0.isWhitespace`). For `new`, keep each token's range.
- **Diff.** Compute `newWords.difference(from: oldWords)` (`CollectionDifference`). Every `.insert(offset:)` marks token `offset` of `new` as changed.
- **Grouping.** Consecutive changed token indices merge into one range, from the first token's `lowerBound` to the last token's `upperBound`, including the whitespace between them.
- **Deletions and whitespace.** Deletions and whitespace-only changes produce no ranges.

**`ios/MagicMeeting/Support/UndoResolver.swift`**
```swift
enum UndoResolution: Equatable {
    case restore(String)
    /// The text changed after the step in a way we cannot reconcile; refuse rather than lose text.
    case conflict
}

enum UndoResolver {
    /// `allowsAppend` is true only for the transcript, the one target that grows by appended segments.
    static func resolve(current: String, before: String, after: String, allowsAppend: Bool) -> UndoResolution
}
```
Rules, checked in this order:
1. If `current == after`, return `.restore(before)`.
2. If `allowsAppend`, `after` is not empty, and the UTF-8 bytes of `current` start with the UTF-8 bytes of `after`:
   - take `suffix` = `current` after the first `after.utf8.count` bytes;
   - if `before` is empty, return `.restore(suffix)` with leading whitespace and newlines trimmed;
   - otherwise return `.restore(before + suffix)`.
   
   The suffix keeps the `"\n\n"` separator that `applySegmentTranscript` added. The prefix check is byte-exact on purpose.
3. Otherwise return `.conflict`. This includes `after` being empty while `current` is not.

**`ios/MagicMeeting/Support/ChangeHighlight.swift`**
```swift
/// Transient: which fragments the last voice edit changed. Never persisted.
struct ChangeHighlight: Equatable {
    let target: EditTarget
    /// The exact text the ranges index into.
    let text: String
    let ranges: [Range<String.Index>]
}
```

**Why highlights are stored this way.** A highlight keeps the exact resulting string together with `Range<String.Index>` into that same string. The view draws it only when `highlight.target == tab.editTarget && highlight.text == currentText`, and in that case builds the `AttributedString` from `highlight.text` itself. Indices are therefore only ever used on the string they came from, and no offset conversion is needed. Any later change to the text (an appended segment, an undo, a manual edit) makes the strings unequal, so a stale highlight is never drawn at wrong positions.

### 2.2 Models and network (Task B)

**`ios/MagicMeeting/Models/Recording.swift`** — add:
```swift
extension Recording {
    func text(for target: EditTarget) -> String
    /// Setting the transcript marks it edited so later appends are glued to the end.
    func setText(_ text: String, for target: EditTarget)
}
```
`setText(_:for: .transcript)` sets `transcript` and `isTranscriptEdited = true`. Undo also leaves it `true`. That is safe because appends then go to the end of the current text, while a rebuild from segment texts would drop other edits.

**`ios/MagicMeeting/Models/EditHistory.swift`** — add:
```swift
enum UndoOutcome: Equatable { case undone, nothingToUndo, conflict }

extension EditHistory {
    /// Most recent step (by createdAt) for `target`.
    @MainActor static func latestStep(of recording: Recording, target: EditTarget) -> EditStep?
    /// Resolves the latest step with UndoResolver (allowsAppend: target == .transcript).
    /// .restore → recording.setText, remove the step from recording.editSteps and context.delete(step).
    /// .conflict → nothing changes and the step is kept. The caller saves.
    @MainActor static func undo(_ recording: Recording, target: EditTarget, in context: ModelContext) -> UndoOutcome
}
```
Steps written by `summarize` regenerations (command `nil`) can be undone like any other step.

**`ios/MagicMeeting/Services/ProxyClient.swift`** — add:
```swift
struct ReplacementsResult: Decodable, Sendable {
    let replacements: [TextReplacement]
}
// in ProxyClient:
/// Cap for Retry-After and backoff; voice edits use a small value to stay near the 5 s target.
var maxRetryDelay: TimeInterval = 30
```
In `retryDelay`, return `min(seconds, maxRetryDelay)` and `min(pow(2, Double(attempt)), maxRetryDelay)`.

**`ios/MagicMeeting/Services/RecordingService.swift`** — add a `// MARK: Voice editing` section:
```swift
/// Recognizes a short spoken command (glossary + settings.recognitionLanguage). Returns trimmed text, possibly empty.
/// Throws VoiceEditError.needsConsent, ProxyError (incl. .notConfigured), CancellationError.
func transcribeCommand(fileURL: URL) async throws -> String

/// Sends the command with the target's text to the LLM, applies the result, records an
/// EditStep (with `command`) and saves. Throws VoiceEditError.needsConsent / .nothingToChange /
/// .textChanged, ProxyError, CancellationError. Never mutates anything when it throws.
func applyCommand(_ command: String, to recording: Recording, target: EditTarget) async throws -> VoiceEditResult

/// EditHistory.undo + save().
func undoLastEdit(of recording: Recording, target: EditTarget) -> UndoOutcome

/// makeClient() with maxAttempts = 2, maxRetryDelay = 1.
private func makeVoiceEditClient() -> ProxyClient?
```
`applyCommand` algorithm:
1. Check consent, then the client, then `before = recording.text(for: target)`. If `before` is empty after trimming, throw `.nothingToChange`.
2. Build the input: `LLMInput(..., command: command, glossary: glossaryTerms(), language: recording.language, uiLanguage: settings.interfaceLanguage)`.
3. **Transcript** (`.editTranscript` → `ReplacementsResult`, input `transcript: before`):
   - after the await, call `try Task.checkCancellation()`; if `!isAlive(recording)`, throw `CancellationError()`;
   - apply the replacements to the current `recording.transcript`, not to `before`. Replacements stay valid if a segment was appended in the meantime;
   - if `appliedCount == 0` or the text did not change, throw `.nothingToChange`;
   - otherwise call `EditHistory.record(recording, target: .transcript, before: current, after: outcome.text, command: command, in: context)`, then `setText`, then `save()`;
   - return `VoiceEditResult(highlight: .init(target: .transcript, text: outcome.text, ranges: outcome.changedRanges), changeCount: outcome.appliedCount)`.
4. **Summary/minutes** (`.editText` → `TextResult`, input `text: before`):
   - after the await, do the same cancellation and alive checks;
   - if `recording.text(for: target) != before`, throw `.textChanged`, so a regenerated summary is never overwritten;
   - if `result.text == before`, throw `.nothingToChange`;
   - otherwise record, `setText`, save, and return the highlight with `WordDiff.changedRanges(from: before, to: result.text)` and `changeCount: nil`.

Nothing is logged: no command, no text, no model output.

### 2.3 Voice edit controller (Task B): `ios/MagicMeeting/Services/VoiceEditor.swift`

```swift
enum VoiceEditError: LocalizedError, Equatable {
    case needsConsent, emptyCommand, nothingToChange, textChanged
    var errorDescription: String? { ... }   // strings in §3 Task C table
}

struct VoiceEditResult {
    let highlight: ChangeHighlight
    /// Replacements applied (transcript); nil for full-text edits.
    let changeCount: Int?
}

enum VoiceEditNotice: Equatable {
    case applied(count: Int?)   // "Changes: %lld" / "Applied"
    case undone
    case microphoneDenied       // the status line offers "Open Settings"
    case message(String)        // already localized: VoiceEditError, ProxyError, AudioRecorderError, undo conflict
    var text: String { ... }
}

@MainActor
@Observable
final class VoiceEditor {
    enum Phase: Equatable { case idle, listening, transcribing, applying }

    static let maxCommandDuration: TimeInterval = 30
    static let minCommandDuration: TimeInterval = 0.5

    private(set) var phase: Phase = .idle
    /// Recognized command, shown while it is applied.
    private(set) var command: String?
    private(set) var notice: VoiceEditNotice?
    private(set) var highlight: ChangeHighlight?
    /// Input level while listening, 0...1. Read only by VoiceEditStatusView.
    var level: Float { recorder.level }

    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var job: (recording: Recording, target: EditTarget, service: RecordingService)?

    init() {}
    func start(recording: Recording, target: EditTarget, service: RecordingService) async
    func finish()
    func cancel()
    func undo(recording: Recording, target: EditTarget, service: RecordingService)
    func clearHighlight()
    func dismissNotice()
}
```
**Recorder.** `VoiceEditor` reuses the `AudioRecorder` class as a separate instance, not the environment instance. It is m4a, 16 kHz, mono, with level metering and interruption handling, so a short command needs nothing new. The meeting recorder is idle whenever the card is visible, because `RecorderView` is a non-dismissable full-screen cover.

**Command file.** The command is recorded to `FileManager.default.temporaryDirectory/voice-command-<UUID>.m4a`, never under `AudioStorage`. It is deleted on every path.

State machine:
```
idle --start (mic granted, recorder.start ok)--> listening
idle --start (mic denied)--> idle [notice .microphoneDenied]
listening --finish | elapsed >= 30 s--> transcribing
listening --cancel | recorder.state != .recording (call/Siri)--> idle (file deleted, no notice)
transcribing --duration < 0.5 s | empty text--> idle [.message(emptyCommand)]
transcribing --text--> applying (command = text)
applying --ok--> idle [highlight = result.highlight, .applied(count)]
transcribing|applying --VoiceEditError/ProxyError/other--> idle [.message(error.localizedDescription)]
transcribing|applying --cancel--> idle immediately; the task's late result is dropped silently
```
**`start`:**
1. Do nothing unless `phase == .idle`.
2. Clear `highlight`, `notice` and `command`.
3. `await recorder.requestPermission()`. If it is denied, set `.microphoneDenied` and return.
4. Check `phase == .idle` again (the await may have overlapped another call).
5. `try recorder.start(url:)`. On error, set `.message(error.localizedDescription)` and delete the file.
6. Store `job` and `fileURL`, set `phase = .listening`, and start a monitor task. Every 200 ms while listening, it does:
   - if `recorder.state != .recording`, call `cancel()`;
   - if `recorder.elapsed >= maxCommandDuration`, call `finish()`.

**`finish`:**
1. Do nothing unless `phase == .listening`.
2. Cancel the monitor task.
3. `let duration = recorder.stop()`.
4. Set `phase = .transcribing`.
5. Start `task = Task { ... }`, which uses only captured locals (url, duration, job) and never `self.fileURL`. Inside it, `defer` removes the file. After every await it checks `Task.isCancelled` before touching `phase`, `notice` or `highlight`.

**Cancellation.** These count as cancellation and are silent: `CancellationError`, `URLError(.cancelled)`, or `Task.isCancelled`.

**`cancel`:**
- in `listening`: stop the recorder, delete the file, set `phase = .idle`;
- in `transcribing` or `applying`: call `task?.cancel()` and set `phase = .idle`. `applyCommand` checks for cancellation before it mutates anything, so a cancelled edit is either fully applied (with an `EditStep`) or not applied at all.

**`undo`:**
1. Do nothing unless `phase == .idle`.
2. Clear the highlight.
3. Call `service.undoLastEdit` and map the result:
   - `.undone` → notice `.undone`;
   - `.nothingToUndo` → notice `nil`;
   - `.conflict` → `.message(String(localized: "The text has changed since this edit, so it can't be undone."))`.

**Consent.** The view checks consent before it enters edit mode or calls `start`. `RecordingService` re-checks it as a defense.

### 2.4 UI (Task C)

**`RecordingDetailView.swift`:**
- **New state:** `@State private var voiceEditor = VoiceEditor()` and `@State private var isVoiceEditing = false`.
- **Action bar** gets a new first button, «Править»: `Label("Edit", systemImage: "waveform")`, `.bordered`, flexible width, placed before Append.
  - Tapping it: if `!settings.hasAIConsent`, set `showConsent = true`; otherwise set `isVoiceEditing = true`.
  - It is disabled when `!canVoiceEdit`.
- **Bottom inset:**
  - `isEditing` → nothing;
  - `isVoiceEditing` → `VoiceEditBar`;
  - otherwise → `actionBar`.
- **Status line.** Between the `Divider` and `content`, show `VoiceEditStatusView(editor:)` plus a `Divider` when `voiceEditor.phase != .idle || voiceEditor.notice != nil`.
- **`textView(_:)`.** If `let h = voiceEditor.highlight, h.target == tab.editTarget, h.text == text`, render `HighlightedText(text: h.text, ranges: h.ranges)`; otherwise render `Text(text)`. Keep `.textSelection(.enabled)` in both cases.
- **Toolbar:**
  - Undo: `Label("Undo", systemImage: "arrow.uturn.backward")`, shown when `!isEditing && EditHistory.latestStep(of: recording, target: tab.editTarget) != nil`, and disabled when `!canUndo`.
  - In voice mode, Done replaces the Menu. It is disabled while `phase != .idle`. It sets `isVoiceEditing = false` and dismisses the notice, but keeps the highlight.
- **Menu «Edit text»** (manual editing):
  - disabled while `phase != .idle`;
  - on tap: `isVoiceEditing = false`, `voiceEditor.clearHighlight()`, `voiceEditor.dismissNotice()`, then the existing behavior.
- **Picker:** `.disabled(isEditing || voiceEditor.phase != .idle)`.
- **`.onChange(of: tab)`:** also clear the highlight and dismiss the notice.
- **Leaving the card:** add `.onDisappear { voiceEditor.cancel() }`.
- **`finishEditing()`:** use `recording.setText(after, for: target)` instead of the switch.
- **`canVoiceEdit`:** requires `voiceEditor.phase == .idle && !currentText.isEmpty`, plus the per-tab condition:
  - transcript: `recording.status == .ready`;
  - summary: `!service.summarizingIDs.contains(recording.id)`;
  - minutes: `true`.
- **`canUndo`:** requires `phase == .idle`, plus the per-tab condition:
  - summary: not summarizing;
  - transcript: `recording.status != .transcribing`.
- **Observation scope.** The detail view body must not read `voiceEditor.level`. Only `VoiceEditStatusView` reads it, so that 10 Hz level updates do not rebuild the full transcript view.

**`ios/MagicMeeting/Views/VoiceEditBar.swift`:**
```swift
struct VoiceEditBar: View {
    let editor: VoiceEditor
    /// False when the open tab has nothing to edit or is busy.
    let canStart: Bool
    /// Parent checks consent and calls `editor.start(recording:target:service:)` in a Task.
    let onStart: () -> Void
}
```
Layout: one round mic button, about 88 pt (`mic.fill`; `stop.fill` while listening; a `ProgressView` while transcribing or applying). Below it, a caption that depends on the phase:
- idle: "Hold or tap and speak a command";
- listening: "Tap to finish";
- busy: a `Cancel` button that calls `editor.cancel()`.

Background: `.bar`, like `actionBar`.

Hold-or-tap gesture: `DragGesture(minimumDistance: 0)` with `@State var pressStart: Date?` and `@State var startedByThisPress: Bool`.
- **Press begins:**
  - if idle and `canStart`: call `onStart()`, set `startedByThisPress = true`, record `pressStart`;
  - if listening: set `startedByThisPress = false`.
- **Press ends:**
  - if listening, `startedByThisPress`, and the press lasted at least 0.4 s: `editor.finish()` (hold mode);
  - if listening and `!startedByThisPress`: `editor.finish()` (second tap in tap mode);
  - otherwise do nothing (first tap of tap mode).

Accessibility: `.accessibilityAddTraits(.isButton)`. The label is "Speak a command" or "Stop and apply". `.accessibilityAction` toggles start and finish, since VoiceOver cannot hold. Haptic: `.sensoryFeedback(.start, trigger: editor.phase == .listening)`.

**`ios/MagicMeeting/Views/VoiceEditStatusView.swift`** — `struct VoiceEditStatusView: View { let editor: VoiceEditor }`. One compact row:
- **listening:** red dot, "Listening…", and `LevelMeterView(level: editor.level)`;
- **transcribing / applying:** `ProgressView` and "Applying…". When `editor.command` is set, it is shown below as `Text(command)`, verbatim, secondary, italic, 2 lines;
- **idle with a notice:** `notice.text`;
  - for `.microphoneDenied`, add an "Open Settings" button (`UIApplication.openSettingsURLString` through `openURL`);
  - add an `xmark` button labelled "Close" that calls `dismissNotice()`.

**`ios/MagicMeeting/Views/HighlightedText.swift`:**
```swift
struct HighlightedText: View {
    let text: String
    let ranges: [Range<String.Index>]
    var body: some View { Text(Self.attributed(text, ranges: ranges)) }
    /// Ranges that do not map into `text` are skipped.
    static func attributed(_ text: String, ranges: [Range<String.Index>]) -> AttributedString
}
```
Use `Range<AttributedString.Index>(r, in: a)` with `.backgroundColor = Color.yellow.opacity(0.35)`.

## 3. Task breakdown

**A, B and C run in parallel.** They touch disjoint files, and all cross-task interfaces are fixed in §2. Do not add stub copies of another task's types, because they would be duplicate definitions after the merge. CI after the orchestrator's merge is the first compile.

### Task A — Pure logic + tests (parallel)

**Creates:**
- `ios/MagicMeeting/Support/TextReplacement.swift`
- `ios/MagicMeeting/Support/WordDiff.swift`
- `ios/MagicMeeting/Support/UndoResolver.swift`
- `ios/MagicMeeting/Support/ChangeHighlight.swift`
- `ios/MagicMeetingTests/ReplacementApplierTests.swift`
- `ios/MagicMeetingTests/WordDiffTests.swift`
- `ios/MagicMeetingTests/UndoResolverTests.swift`

**Provides:** `TextReplacement`, `ReplacementOutcome`, `ReplacementApplier.apply`, `WordDiff.changedRanges`, `WordDiff.maxTokens`, `UndoResolution`, `UndoResolver.resolve`, `ChangeHighlight`.

**Consumes:** `EditTarget` (existing).

**Tests.** Assert ranges through `text[range]` substrings.
- `ReplacementApplierTests`:
  - first-only versus `all`;
  - Cyrillic text with an emoji before the match (ranges still correct);
  - two sequential replacements where the second shifts the first's range;
  - a second replacement inside the first's inserted text, which merges into one range;
  - a deletion (empty replace) gives count 1, no range, and an earlier mark after it shifts correctly;
  - `find` not present gives count 0 and unchanged text;
  - empty `find` and `find == replace` are ignored;
  - `"a"→"aa"` with `all: true` terminates and counts every original occurrence;
  - adjacent ranges merge.
- `WordDiffTests`:
  - identical text gives `[]`;
  - one changed word gives exactly that word;
  - three inserted words in a row give one range including the inner spaces;
  - deletion only gives `[]`;
  - a whitespace or newline change only gives `[]`;
  - Cyrillic text;
  - more than `maxTokens` tokens gives `[]`.
- `UndoResolverTests`:
  - equal to `after` restores `before`;
  - an appended `"\n\nX"` (with `allowsAppend` true) gives `before + "\n\nX"`;
  - the same input with `allowsAppend` false gives a conflict;
  - unrelated text gives a conflict;
  - `after` empty with non-empty current gives a conflict;
  - `before` empty with an appended suffix gives the trimmed suffix;
  - a two-step chain (A→B, B→C, then append) undoes back to A plus the suffix.

**Acceptance:** no imports other than Foundation; functions under 50 lines; all tests pass in CI.

### Task B — Models, networking, VoiceEditor (parallel)

**Modifies:**
- `ios/MagicMeeting/Models/Recording.swift`
- `ios/MagicMeeting/Models/EditHistory.swift`
- `ios/MagicMeeting/Services/ProxyClient.swift`
- `ios/MagicMeeting/Services/RecordingService.swift`

**Creates:**
- `ios/MagicMeeting/Services/VoiceEditor.swift`
- `ios/MagicMeetingTests/EditHistoryTests.swift`

**Provides:**
- `Recording.text(for:)` and `Recording.setText(_:for:)`
- `UndoOutcome`, `EditHistory.latestStep(of:target:)`, `EditHistory.undo(_:target:in:)`
- `ReplacementsResult` and `ProxyClient.maxRetryDelay`
- `RecordingService.transcribeCommand(fileURL:)`, `applyCommand(_:to:target:)`, `undoLastEdit(of:target:)`
- `VoiceEditError`, `VoiceEditResult`, `VoiceEditNotice`, `VoiceEditor`

**Consumes:** Task A types; existing `AudioRecorder`, `EditHistory.record`, `ProxyClient.llm` and `ProxyClient.transcribe`.

**Tests.** `EditHistoryTests.swift` runs `@MainActor` on an in-memory `ModelContainer(for: Recording.self, AudioSegment.self, Highlight.self, EditStep.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))`:
- two steps on summary undo in reverse order and remove both steps;
- undo on transcript keeps the summary step and leaves `isTranscriptEdited == true`;
- a conflict keeps the step and leaves the text unchanged;
- `nothingToUndo` when there are no steps;
- `latestStep` picks the newest by `createdAt` for the right target;
- `setText(.transcript)` sets `isTranscriptEdited`.

The same file holds `ReplacementsResultDecodingTests`, which decodes `{"replacements":[{"find":"a","replace":"b","all":true}]}` and `{"replacements":[]}`.

**Acceptance:**
- Swift 6 strict concurrency is clean, and `VoiceEditor` is `@MainActor @Observable`.
- The temp file is deleted on every path.
- A cancelled or failed command never mutates text or creates a step.
- No `print` or logging of commands or texts.
- Every user-facing string uses `String(localized:)` with exactly the English keys in Task C's table.

### Task C — UI and localization (parallel)

**Modifies:**
- `ios/MagicMeeting/Views/RecordingDetailView.swift`
- `ios/MagicMeeting/Resources/Localizable.xcstrings` (the only task that touches it)

**Creates:**
- `ios/MagicMeeting/Views/VoiceEditBar.swift`
- `ios/MagicMeeting/Views/VoiceEditStatusView.swift`
- `ios/MagicMeeting/Views/HighlightedText.swift`

**Consumes:** `VoiceEditor` and its API, `VoiceEditNotice`, `ChangeHighlight`, `EditHistory.latestStep`, `Recording.setText`, `RecordingService.summarizingIDs`, `AppSettings.hasAIConsent`, `ConsentView`, `LevelMeterView`.

**Strings.** Add these keys, `state: translated`, matching the file's existing format. Keys that already exist and are reused: "Cancel", "Done", "Close", "Open Settings".

| Key (en) | ru | Defined by |
|---|---|---|
| Edit | Править | C |
| Undo | Отменить | C |
| Listening… | Слушаю… | C |
| Applying… | Применяю… | C |
| Hold or tap and speak a command | Удерживайте или нажмите и скажите команду | C |
| Tap to finish | Нажмите, чтобы закончить | C |
| Speak a command | Сказать команду | C |
| Stop and apply | Закончить и применить | C |
| Changes: %lld | Изменений: %lld | B |
| Applied | Применено | B |
| Undone | Отменено | B |
| Allow microphone access in Settings to edit by voice. | Разрешите доступ к микрофону в Настройках, чтобы править голосом. | B |
| Allow sending data to the AI service to edit by voice. | Разрешите отправку данных в AI-сервис, чтобы править голосом. | B |
| Didn't catch that. Try again. | Команда не распознана. Попробуйте ещё раз. | B |
| Nothing to change for this command. | По этой команде менять нечего. | B |
| The text changed while the command was being applied. Try again. | Текст изменился, пока применялась команда. Попробуйте ещё раз. | B |
| The text has changed since this edit, so it can't be undone. | Текст изменился после этой правки, отменить её нельзя. | B |

**Tests:** none for the UI. CI building is the check. Optionally add one `HighlightedTextTests` case: `attributed` sets a background color on exactly the given range and ignores a range from a different string's indices.

**Acceptance:**
- Every new UI string is in the table.
- The detail view body does not read `voiceEditor.level`.
- Picker, Done and «Edit text» are locked while the editor is not idle.
- The highlight is cleared on tab switch, on the next command, on manual editing and on undo.
- The existing manual edit, append, copy and share keep working.

**Merge order:** A, then B, then C. There are no shared files, so no conflicts are expected. Run CI once after all three are merged.

## 4. Review focus

**swift-reviewer**
- `@MainActor` isolation of `VoiceEditor`'s tasks; `[weak self]` in the monitor loop.
- `@ObservationIgnored` on the recorder and tasks.
- `String.Index` used only on its own string; no index used after a mutation inside `ReplacementApplier`.
- `ranges(of:)` and `firstRange(of:)` availability (deployment target is iOS 17).
- `Range<AttributedString.Index>(_:in:)` usage.
- Gesture state logic for hold versus tap.
- Over-rendering: the 10 Hz level must not rebuild the transcript text.

**silent-failure-hunter**
- Every `catch` in `VoiceEditor` either sets a notice or is a real cancellation; `URLError.cancelled` must not show as an error.
- The temp file is deleted when `start` fails, on cancel, and when the task ends.
- `applyCommand` never mutates before its last throw point.
- An undo conflict keeps the text and says so.
- `try?` and `save()` failures are not hidden in new code paths.
- A failed `requestPermission` or `recorder.start` is surfaced.

**security-reviewer**
- No logging of commands, transcripts or model output on the client.
- The command audio lives only in tmp and is deleted.
- Consent is checked before any upload, in both the view and the service.
- The replacements from the proxy are untrusted. With an empty `find`, a huge `all`, or many replacements, the applier must stay bounded, with no infinite loop and memory proportional to the output.

## 5. Risks and on-device checks

**Risks:**
- **Latency vs. 5 s.** A 120 s request timeout plus retries could hang. Mitigations: `maxAttempts = 2`, `maxRetryDelay = 1`, and a visible Cancel. The real numbers need to be measured on a pilot.
- **Very long transcripts (up to 3 h).** The whole transcript goes to `edit_transcript`, and the LLM context or `MAX_LLM_BODY_KB` (1 MB) could be exceeded. This is not addressed in stage 4. Note any 413/502 errors seen on the pilot.
- **Highlights in long text** are not scrolled into view. The `Changes: N` notice compensates. Scroll-to-first-change is a possible follow-up.
- **Permission prompt during a hold.** On the first use, the press can end before listening starts, and the flow then falls back to tap mode. That is acceptable.
- **SwiftData in-memory tests in CI.** If the container fails to start in the test host, keep the `UndoResolver` tests and move the `EditHistory` checks behind them.

**Verify on iPhone:**
- Hold-to-talk and tap-tap both work, the level meter moves, and the 30 s auto-stop applies.
- Microphone denial shows the notice and "Open Settings".
- An incoming call or Siri during listening cancels cleanly.
- Bluetooth/AirPods input works for commands.
- "Замени Курбацкий на Курбатский везде" on a real transcript is highlighted correctly and finishes in 5 s or less on LTE.
- "Сократи summary до трёх пунктов" gives a word-level highlight.
- Multi-step Undo works across manual and voice edits; undo still works after appending a segment to an edited transcript.
- Leaving the card mid-request leaves no edit or step behind.
- Airplane mode shows a readable error and leaves the text unchanged.
- Dark mode contrast of the highlight color; VoiceOver activation of the big button.
