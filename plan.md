# Buddy — Plan

## Goal

Buddy is a macOS helper that works right at your cursor (invisible until you need it). You use it to point at things on screen — clicking, circling, highlighting — and Buddy explains exactly what you pointed at and how it works.

When you first open the app, you connect an AI provider (starting with Claude via the current subscription). That AI receives what you pointed at and produces the explanation.

**Current focus (MVP):** highlight by drawing a circle.

1. Press a key combination → Buddy enters **drawing mode**.
2. Hold the primary mouse button and draw a circle/shape around something.
3. Release → Buddy captures the screen region, sends it (with the drawn annotation) to Claude.
4. The explanation streams into a bubble next to the cursor.
5. Esc (or the same shortcut) exits drawing mode.

---

## Topics to decide (one by one)

Each topic gets discussed, decided, and the decision written back here. **All MVP topics decided (2026-09-29). MVP flow working end to end (2026-09-29).**

| # | Topic | Status | Decision |
|---|-------|--------|----------|
| 1 | Tech stack & app type (Swift/SwiftUI + AppKit, menu bar app vs Dock app, min macOS version) | Decided | Swift + SwiftUI for all UI; AppKit only where SwiftUI can't (overlay `NSPanel`s, global mouse/key monitoring, window levels). Target the latest two macOS versions: **macOS 26 Tahoe and macOS 27 Golden Gate** (deployment target 26.0). Menu bar app only, **no Dock icon** (`LSUIElement = YES`). |
| 2 | AI connection — how to use the Claude subscription (Claude Code CLI as backend vs Anthropic API key vs other); auth & ToS check | Decided | **Primary: the user's own installed Claude Code CLI** (`claude -p`, non-interactive, streamed JSON output), signed in via Anthropic's own login flow. Buddy never sees or stores Claude tokens. Usage counts toward the user's plan limits. **Fallback (later): Anthropic API key** (Console, stored in Keychain). **Not allowed:** building our own claude.ai login or reusing subscription OAuth tokens. If Buddy is ever distributed as a product, re-check the Commercial Terms. |
| 3 | Cursor companion — look, size, offset, animation, multi-monitor behavior | Decided | **No cursor dot** (removed 2026-09-29, not needed). Buddy is invisible until drawing mode; only the answer bubble appears next to the cursor. |
| 4 | Global shortcut for drawing mode (which keys, toggle vs hold, customizable?) | Decided | **⌃⌥Space (Control+Option+Space)** — chosen as more intuitive than ⌃⌥Space. ⚠️ macOS uses it by default for "Select next source in Input menu" (only matters with 2+ keyboard input sources) → turn that off in System Settings → Keyboard → Keyboard Shortcuts → Input Sources if needed. Registered as a normal global hotkey (Carbon `RegisterEventHotKey`) → **no extra permission needed**. If registration fails (another app owns it), Buddy says so. **Toggle:** shortcut → drawing mode on; draw one shape → auto-send on mouse release; Esc or shortcut again → cancel. Customizable later. |
| 5 | Drawing mode UX — overlay, stroke style, one vs multiple shapes, when to "submit", cancel | Decided | Screen **doesn't change** (no dim); only the cursor becomes a crosshair. Stroke: **solid red, 3 pt**. One shape per request, auto-sent on mouse release; tiny accidental strokes are ignored; drawing stays on the display where it started. The circle **stays visible until the answer appears**, then fades out. |
| 6 | Screen capture — what to send (cropped region, full screen with annotation, both), resolution, excluding Buddy's own windows | Decided | Send **one image: the whole screen (the display where the circle was drawn) with the red circle drawn onto it.** The circle = the main question, the rest of the screen = context. Capture via ScreenCaptureKit **without Buddy's own windows**, then draw the red stroke onto the image ourselves. Downscale to Claude's recommended image size (~1568 px long edge). If small things turn out blurry, add a close-up crop as a 2nd image. |
| 7 | Extra context — frontmost app name, window title, Accessibility tree text under the circle | Decided | Send **app name + window title** of the window under the circle (e.g. "Xcode — ContentView.swift") as text next to the image. App name via `NSWorkspace`, window title via ScreenCaptureKit window info (covered by Screen Recording). **No Accessibility text** for MVP (would need an extra permission). |
| 8 | Prompt design — what Claude is asked, tone, length, language | Decided (tune later) | Use **Haiku** (fast, light). Replace Claude Code's default system prompt with Buddy's own (`--system-prompt`). Always answer in a **fixed short JSON format**: `title` (≤6 words), `what` (1 sentence), `how` (≤3 bullets, ≤15 words each). Thinking off (`MAX_THINKING_TOKENS=0`), safety cap 1024. Verified in Spike 2. |
| 9 | Answer UI — bubble near cursor, streaming, follow-up questions, copy, dismiss | Decided (MVP) | A black **message bubble grows out next to the cursor** showing title / what / how. The bubble **follows the cursor** and flips side near screen edges so it stays visible. Closes on **Esc or any click** (the click still goes through to the app), then shrinks back toward the cursor. **No extras** for MVP (no copy, no follow-ups). While waiting: small "Thinking…" bubble; errors shown in the same bubble. |
| 10 | Permissions & onboarding (Screen Recording, Accessibility, Input Monitoring) | Decided | Only **Screen Recording** is needed (shortcut, mouse tracking, clicks and temporary Esc hotkey need none). One onboarding screen: checks Screen Recording + Claude Code installed & logged in, with a button/instructions for each. |
| 11 | Privacy — what leaves the machine, redaction, history on/off | Decided (MVP) | Screenshot + app/window title go **only to Claude via the user's own Claude Code**. Nothing saved to disk (temp data in memory only), **no history**, `--no-session-persistence`. |
| 12 | Distribution — signing, notarization, sandbox or not, auto-updates | Decided (MVP) | Build & run **from Xcode on David's Mac** for now. No App Sandbox (needs to launch `claude`). Developer ID signing + notarization only when sharing with others; no auto-updates for MVP. |

---

## TODO

Legend: `[x]` done & verified · `[~]` implemented, needs testing · `[ ]` not started

### Phase 0 — Setup
- [x] Decide topic 1 (stack, min macOS version) → SwiftUI + AppKit bridges, macOS 26+
- [x] Decide menu bar app vs Dock app → menu bar only, no Dock icon
- [x] Create Xcode project (menu bar app, `LSUIElement`) → `Buddy.xcodeproj`, target macOS 26.0, bundle id `com.davidkecskes.buddy`, no sandbox, hardened runtime, sign to run locally
- [x] Open in Xcode, build & run (⌘R) → menu bar icon appears, no Dock icon (verified 2026-09-29)
- [x] README, `.gitignore`
- [ ] Git: later (a `.git` folder already exists from setup, no commits)
- [x] Folder structure: `App`, `Input`, `Overlay`, `Capture`, `AI`, `UI`
- [x] Dependencies: none needed (hotkey via Carbon, capture via ScreenCaptureKit)

### Phase 1 — Cursor companion
- [x] ~~Black dot following the cursor~~ → built, then **removed** (not needed)
- [x] Global mouse tracking kept for the answer bubble → `Input/MouseTracker.swift`
- [~] Menu bar **panel** (drops down from the icon, `MenuBarExtra` window style) → `UI/MenuPanelView.swift`. Kept minimal:
  - **How to draw** (⌃⌥Space → circle → release; Esc/click closes)
  - **Model picker**: Haiku (fast) / Sonnet (smarter), saved; warm process restarted for the new model
  - **Quit Buddy**
- [ ] (Later, if needed) status in the panel: Claude Code connected/logged in, Screen Recording, shortcut, plan usage

### Phase 2 — AI connection
- [x] Decide topic 2 → use the user's Claude Code CLI (`claude -p`); API key as a later fallback
- [x] Install Claude Code and log in with the same Claude account used in the Claude app (3SS account); confirm Claude Code is enabled for the org
- [x] Detect the `claude` binary (`~/.local/bin`, Homebrew, login-shell `command -v`); login errors surface as API error → `AI/ClaudeCodeClient.swift`
- [ ] First-launch "Connect your AI" screen: if missing → install instructions; if logged out → tell user to run `claude` and log in via Anthropic's flow
- [x] Spike: send an image + prompt through `claude -p` → both work; **chosen: `--input-format stream-json` with a base64 image block** (see findings below)
- [x] Spike 2: Haiku + own system prompt + fixed JSON format + no tools/MCP → ~4 s total, works (see findings)
- [x] Parser: extract the JSON object even if wrapped in ```json fences (first `{` … last `}`) → `AI/Explanation.swift`
- [~] Warm process: always keep one `claude` process started and waiting on stdin; each request uses it and a new one is started right away → skips the ~1.8 s startup. One process per request (no shared context between screenshots) → `AI/WarmClaudeProcess.swift`
- [~] Setting to switch model (Haiku default, Sonnet for harder screens) → in the menu panel
- [x] Parse `--output-format stream-json` (wait for the `result` event); no tools, no MCP; 60 s timeout
- [ ] (Later) provider protocol so other AIs can be added
- [ ] (Later) API key provider, key stored in Keychain
- [x] Test call from the app: menu → Test Claude (text only; verified 2026-09-29)

### Phase 3 — Drawing mode
- [x] Decide topic 4 → ⌃⌥Space, toggle, auto-send on mouse release
- [x] Decide topic 5 → no dim, crosshair cursor, red 3 pt stroke, circle stays until answer
- [x] Register ⌃⌥Space as a global hotkey (Carbon `RegisterEventHotKey`) → toggle drawing mode → `Input/HotKey.swift`; also "Draw" in the menu
- [x] If registration fails (another app owns the shortcut) → alert
- [x] On enter: invisible full-screen overlay on each display that captures mouse input; crosshair cursor → `Overlay/DrawingController.swift`
- [x] Draw freehand red 3 pt path while primary button is held; ignore tiny strokes (<12 pt)
- [x] Compute bounding box / center of the drawn shape
- [x] Auto-send on mouse release; Esc or ⌃⌥Space again cancels
- [x] Keep the circle visible while waiting; fade it out when the answer appears

### Phase 4 — Screen capture
- [x] Decide topic 6 → whole screen + red circle drawn on it, one image
- [x] Request Screen Recording permission (at launch + on first capture)
- [x] Capture the display where the circle was drawn (ScreenCaptureKit), excluding Buddy's windows → `Capture/ScreenCapturer.swift`
- [x] Draw the red stroke onto the captured image → `Capture/ScreenshotAnnotator.swift`
- [x] Capture directly at ≤1568 px long edge, JPEG (quality 0.8), base64 in the request
- [x] System prompt: "the red circle marks what the user is asking about; use the rest of the screen as context"
- [ ] Test on small UI elements; if blurry, add a close-up crop as a 2nd image

### Phase 5 — Explain
- [x] Decide topics 7 and 8 → app + window title; Haiku + fixed JSON
- [x] Find the window under the circle's center; get its app name + window title → `Capture/WindowContext.swift`
- [x] Build prompt + image, send through Claude Code
- [x] Decide topic 9 → bubble follows cursor, Esc/any click closes, no extras
- [x] Answer bubble: black message cloud grows out next to the cursor (title / what / how), follows the cursor, flips at screen edges → `UI/BubbleView.swift`, `UI/BubbleController.swift`
- [x] Close on Esc or any click → shrink back toward the cursor. Click: global mouse-down monitor (no permission needed for mouse events). Esc: register Esc as a temporary hotkey only while the bubble is open (a global key monitor would need Accessibility)
- [x] Loading ("Thinking…") / error / no-permission states shown in the bubble

### Phase 6 — Polish & ship
- [x] Decide topics 10, 11, 12 → Screen Recording only; nothing stored; run from Xcode
- [ ] Onboarding screen: Screen Recording permission + Claude Code installed/logged in
- [ ] Settings window (shortcut, AI provider, appearance)
- [ ] No App Sandbox (Buddy must launch the `claude` CLI) → Developer ID signing + notarization, outside the Mac App Store
- [ ] Sign & notarize; install on a clean Mac to test

### Later (after MVP)
- [ ] Bubble design polish (look, animation)
- [ ] Click-to-explain (single click on a UI element)
- [ ] Highlight / rectangle / arrow tools
- [ ] Follow-up chat on the same capture (reuse the same `claude` process with stdin kept open)
- [ ] Voice input / spoken answers
- [ ] More AI providers

---

## Findings

### Spike 1 — `claude -p` with an image (2026-09-29, Claude Code 2.1.284)

| | A: file path + Read tool | B: stream-json, base64 image |
|---|---|---|
| Works | Yes | Yes |
| Total time | ~22 s | ~14 s (first answer text ~10.7 s) |
| Needs file on disk / Read permission | Yes | No |
| Follow-up questions in same process | No | Yes (keep stdin open, send next message) |

- Auth works through the subscription (`apiKeySource: none`); rate-limit info comes back in the stream (5-hour / 7-day utilization) → can show usage in Buddy.
- Default call loads the whole user setup: all tools, hooks, plugins, skills, MCP servers (mempalace), Opus with thinking. That makes it slow and heavy (~12k tokens of setup per call).
- Answer arrived as one message, not word by word → need `--include-partial-messages` for live streaming.


### Spike 2 — Haiku + own system prompt + JSON format (2026-09-29)

- Attempt 1 failed: `CLAUDE_CODE_MAX_OUTPUT_TOKENS=300` → "response exceeded the 300 output token maximum" after ~18 s. Claude Code **errors instead of cutting off**, and the cap probably also counts thinking tokens. → Don't use a tight hard cap; keep answers short via the prompt, turn thinking off, keep a loose safety cap (~1024).
- Good sign: `cache_creation_input_tokens: 0` → the heavy default setup is gone.
- Attempt 2 worked: `MAX_THINKING_TOKENS=0`, cap 1024, `--model haiku` (→ `claude-haiku-4-5`), `--system-prompt` (own prompt), `--tools ""`, `--strict-mcp-config`, `--no-session-persistence`.
  - **~4.2 s total**: ~2.2 s to first token, ~2.4 s API time, ~1.8 s is Claude Code process startup.
  - 97 output tokens, 0 thinking, no retries.
  - Format held (title / what / how ≤3), but Haiku **wrapped it in ```json fences** despite the instruction → parser must tolerate that.
  - Quality: Haiku called the 46:27 timer "current video position"; Opus read it as a countdown. Haiku is good enough as default, but keep a model switch.

**Command Buddy will run (baseline):**

```bash
MAX_THINKING_TOKENS=0 CLAUDE_CODE_MAX_OUTPUT_TOKENS=1024 claude -p \
  --input-format stream-json --output-format stream-json --verbose \
  --model haiku --system-prompt "<Buddy system prompt>" \
  --tools "" --strict-mcp-config --no-session-persistence
```


### Bug — stuck on "Thinking…" forever (2026-09-30)

- Symptom: bubble stays on "Thinking…", no answer and no timeout error.
- Causes found in code: (1) ScreenCaptureKit calls had no timeout; (2) the 60 s Claude timeout relied on stdout hitting EOF after SIGTERM, which a lingering child could block; (3) the warm `claude` process could sit idle for hours (Mac sleep, token expiry, CLI auto-update) and go stale.
- Fix: `AI/Deadline.swift` (`withDeadline` that always fires); 10 s capture deadline; Claude timeout 30 s + hard backstop with SIGKILL escalation; warm process discarded after 10 min idle.
- [~] Needs testing on device.
- Added Debug Console (menu panel → "Debug Console"): live list of claude processes, every stream-json event, stderr, exit codes, timeouts. In-memory only; screenshot never logged. Files: `Debug/DebugLog.swift`, `Debug/DebugConsoleView.swift`.
- Root cause of the hang (likely): `claude` inherited cwd `/`, scanned protected folders (~/Music, ~/Documents…) → macOS TCC prompts attributed to Buddy ("would like to access Apple Music…"), and `claude` blocks until answered. Fix: `claude` now runs in an empty temp folder (`WarmClaudeProcess.workingDirectory`). Buddy needs no folder / media permissions — deny them.
- Prompts continued (Documents, Desktop, network volume) after the cwd fix → caused by the user's own Claude Code setup loading (hooks/plugins/skills/settings). Added `--setting-sources "" --restricted --disable-slash-commands --no-chrome` (checked against Claude Code 2.1.285 `--help`). Not `--bare`: it forces API-key auth.
- Screen Recording asked again after every build: project was ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`), so each build gets a new code signature and macOS treats it as a new app. Fix: sign with a stable Apple Development identity (set a Team in Signing & Capabilities). macOS may still re-confirm screen recording periodically; that's system behaviour.
- Real cause of the 30 s "Thinking…" (seen in Debug Console): all stdout (even `system/init`) arrived only after the timeout's SIGTERM, although the API took ~2 s. Claude Code emits nothing until stdin gets EOF / exit. Fix: close stdin right after writing the message. Consequence: follow-up questions on the same process (Spike 1 idea) won't work this way — later needs a new process per message, or `--resume`.
