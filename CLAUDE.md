# CLAUDE.md

This file gives Claude Code guidance for working in this repository.

## What this is

**Clicky** is a macOS menu bar app (no Dock icon, `LSUIElement = YES`) — a cursor companion. The user presses **⌃⌥Space**, circles something on screen, and on mouse release Clicky screenshots that display with the red circle drawn on it, sends it to Claude through the user's **own installed Claude Code CLI** (`claude -p`), and shows a short explanation in a black bubble that follows the cursor.

`plan.md` is the source of truth for product decisions (12 decided topics), the phased TODO list (`[x]` done · `[~]` implemented, needs testing · `[ ]` not started), and spike findings. **Read it before changing behaviour, and update it (decision table / TODO / findings) when a decision or status changes.**

## Build & run

- Requirements: macOS 26+ (deployment target 26.0, targeting Tahoe + Golden Gate), Xcode 26+, Claude Code installed and logged in.
- Open `Clicky.xcodeproj` in Xcode, ⌘R. CLI alternative: `xcodebuild -project Clicky.xcodeproj -scheme Clicky -configuration Debug build`.
- No tests, no linter, **no third-party dependencies** (hotkey via Carbon, capture via ScreenCaptureKit). Keep it that way unless there's a strong reason.
- Project uses Xcode 16+ **file-system-synchronized groups** (`objectVersion = 77`): new `.swift` files dropped into `Clicky/` are picked up automatically — no need to edit `project.pbxproj`.
- Bundle id `com.davidkecskes.clicky`; **App Sandbox OFF** (must launch `claude`), hardened runtime on, Info.plist generated from build settings (`INFOPLIST_KEY_*`).
- Timing log per request is printed to the Xcode console: `[Clicky] capture … · Claude … · total …`.
- Git: repo initialised, no commits yet.

## Swift settings that matter

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + `SWIFT_APPROACHABLE_CONCURRENCY = YES`: every type is **main-actor by default**. Anything that must run off-main (process I/O, value types crossing tasks) is explicitly marked `nonisolated` (see `AI/`). Follow that pattern.
- Blocking work (reading `claude` stdout) runs on GCD queues, not the Swift concurrency pool.

## Architecture (`Clicky/`)

| Folder | Files | Role |
|---|---|---|
| `App/` | `ClickyApp` (SwiftUI `MenuBarExtra`, `.window` style), `AppDelegate` (ignores SIGPIPE, calls `AppModel.shared.start()`), `AppModel` | `AppModel` is the `@Observable` singleton orchestrating the whole flow: hotkeys, drawing → capture → Claude → bubble, model choice (`ClaudeModel` haiku/sonnet in UserDefaults key `model`), `requestID` to drop stale answers, click monitors to close the bubble |
| `Input/` | `HotKey`, `MouseTracker` | Carbon `RegisterEventHotKey` (no permission needed). Esc is registered as a hotkey **only while drawing/bubble is active** — a global key monitor would need Accessibility. Global+local `NSEvent` mouse monitors (no permission needed) |
| `Overlay/` | `DrawingController` | One invisible full-screen `NSPanel` per display, crosshair cursor, red 3 pt freehand stroke, strokes < 12 pt ignored, emits `DrawnShape` (global points, bottom-left origin). Also holds `ClickyColors` |
| `Capture/` | `ScreenCapturer`, `ScreenshotAnnotator`, `WindowContext` | ScreenCaptureKit capture of the circled display **excluding Clicky's own windows**, ≤1568 px long edge; annotator draws the stroke onto the image and encodes JPEG q0.8; `WindowContext` gives "App: X — Window: Y" via `CGWindowList` |
| `AI/` | `ClaudeCodeClient`, `WarmClaudeProcess` (+ `ClaudeProcessPool` actor), `ProcessRunner`, `ClickyPrompt`, `Explanation`, `ClaudeCodeError` | See below |
| `UI/` | `BubbleController`, `BubbleView`, `MenuPanelView` | Click-through panel following the cursor, flips left/above near screen edges; phases thinking / answer / error. Menu panel: how-to, model picker, quit |

### Claude integration (the core — be careful here)

- Command baseline (from Spike 2, ~4 s end-to-end with Haiku):
  `MAX_THINKING_TOKENS=0 CLAUDE_CODE_MAX_OUTPUT_TOKENS=1024 claude -p --input-format stream-json --output-format stream-json --verbose --model <haiku|sonnet> --system-prompt <ClickyPrompt.system> --tools "" --strict-mcp-config --no-session-persistence`
- Input: one newline-delimited stream-json user message with a base64 image block + text (context + question). Output: read stdout until the `result` event; `rate_limit_event` gives 5-hour / 7-day plan utilisation (`ClaudeUsage`, not yet shown in UI).
- **Warm process pool**: one `claude` process is always pre-started and waiting on stdin (skips ~1.8 s startup). Each process answers **exactly one** message, then stdin is closed and it exits; the pool immediately warms the next. Changing model re-prewarms. 60 s timeout.
- `claude` binary lookup: `~/.local/bin`, `~/.claude/local`, `/opt/homebrew/bin`, `/usr/local/bin`, then `zsh -lc 'command -v claude'`. GUI apps don't inherit the shell PATH, so `environment()` rebuilds it.
- Answer format is fixed JSON `{title ≤6 words, what 1 sentence, how ≤3 bullets}`. Haiku often wraps it in ```json fences → `Explanation.parse` takes first `{` … last `}`. Keep the parser tolerant.
- Don't use a tight `CLAUDE_CODE_MAX_OUTPUT_TOKENS`: Claude Code errors instead of truncating.

## Hard constraints (from plan.md decisions)

- **Auth/ToS**: only use the user's own logged-in Claude Code CLI. Never build a claude.ai login or reuse subscription OAuth tokens. Later fallback = Anthropic API key in Keychain.
- **Privacy**: screenshot + app/window title go only to Claude via Claude Code; nothing written to disk, no history, `--no-session-persistence`.
- **Permissions**: only Screen Recording. Don't introduce anything needing Accessibility or Input Monitoring without revisiting the plan. Don't gate capture on `CGPreflightScreenCaptureAccess()` (stale "no" for dev builds) — try, and only blame permission on failure.
- **UI**: SwiftUI for all UI; AppKit only where SwiftUI can't (overlay `NSPanel`s, global monitors, window levels). No cursor dot (removed). Screen isn't dimmed in drawing mode. The circle stays visible until the answer arrives, then fades.
- Coordinates: AppKit global points use bottom-left origin; `CGWindowList` uses top-left relative to the primary display — convert explicitly (see `WindowContext`, `ScreenshotAnnotator`).

## Open work (see plan.md TODO for the full list)

Onboarding screen (Screen Recording + Claude Code installed/logged in), settings window (shortcut, provider), test small-element legibility (maybe add close-up crop as 2nd image), provider protocol + API-key provider, signing/notarization. Later: click-to-explain, more shape tools, follow-up chat on same capture, voice.

## Conventions

- Small, focused files per concern; doc comments (`///`) explain *why* (permissions, timing, platform quirks).
- User-facing error messages are plain-language and actionable (see `ClaudeCodeError`, `CaptureError`).
