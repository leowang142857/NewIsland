# NewIsland

NewIsland is a top-of-screen work island for Mac: deadlines, focus, and Ask Grok sit in one strip beside the notch, so you don't switch windows. Mac 上的灵动岛，把今天要做的事和问 Grok 放在屏幕最上面。 Keywords: Mac Dynamic Island, macOS menu bar island, notch productivity, deadline focus timer, ask Grok on Mac, 灵动岛 Mac, 顶部任务条, 截止日期 专注计时.

The app is written in Swift with SwiftUI and AppKit. The core logic lives in a
platform-independent Swift package (`GrokIslandCore`) with its own test suite.

> **Language note:** the in-app interface is currently in Chinese, the deadline
> parser understands Chinese date and time expressions, and Grok is asked to
> answer in Chinese. UI labels are quoted in this README with an English
> translation.

---

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Build and run with Xcode](#build-and-run-with-xcode)
- [Configuration](#configuration)
- [Privacy, permissions, and secrets](#privacy-permissions-and-secrets)
- [Where data is stored](#where-data-is-stored)
- [Headless core and tests (macOS or Linux)](#headless-core-and-tests-macos-or-linux)
- [Architecture](#architecture)
- [Project layout](#project-layout)
- [Contributing](#contributing)

---

## Features

### The island

- The panel is docked at the top center of the screen and cannot be dragged
  around. When collapsed it is a thin **peek strip**.
- **Hover over the peek strip** to slide the island open. Move the pointer away
  and it retracts after about half a second. It stays open while it is pinned
  (pin button in the header), while you drag something over it, and while a
  Local run is waiting for your confirmation.
- A **collapse lock** sits at the left end of the peek strip. Click it (it turns
  amber) to keep the island collapsed even when the pointer is over the strip or
  you drag files across it; click again to unlock. Hovering the lock itself does
  not expand the island, so you can always reach it. The lock state is remembered
  across launches.
- On Macs with a notch, the peek strip hugs the camera housing and only shows
  about 56 pt on each side of the notch; the expanded island drops just below it.
  On screens without a notch it is a ~164 pt capsule under the menu bar.
- Hover detection polls `NSEvent.mouseLocation`, so no Accessibility or Input
  Monitoring permission is needed.

When expanded, the island is organized in layers, from top to bottom:

1. **Task lights** — one light per running or recently finished task.
2. **DDL energy bar** — all open deadlines in one bar.
3. **Grok quick actions** — three one-tap buttons plus an "Ask Grok" field.
4. **Modules / run records** — your module grid, or the history of runs.

When collapsed, the peek strip shows the collapse lock on the far left, then up
to a few task lights (two lights plus a count when there are more than three),
and the countdown of the most pressing deadline on the right (split across both
sides of the notch on notched screens).

### Modular island (function modules)

Modules are persistent, user-defined skills — not automatically generated task
chunks. Each module has a name, a prompt, and an executor:

| Executor | What it does |
| --- | --- |
| **Grok Bot** | Sends the prompt and the dropped resources to a Grok model via a Cursor Cloud Agent (see [Ask Grok](#ask-grok-via-cursor-cloud-agents)). |
| **Local** | Runs on your Mac: optionally opens the dropped files, and optionally runs a shell command that you type and confirm. |

How to use them:

- Click **新建模块** ("New module") to create one. With an empty list you can
  also click **载入示例** ("Load examples") to add three demo modules: 翻译
  (Translate), 整理笔记 (Organize notes), and 打开文件 (Open files).
- Click a tile to edit or delete the module.
- **Drag files, folders, or links onto a tile** to run that module on them.

Drop feedback is explicit so you always know what happened:

- While dragging over the island, a hint names the target module and whether it
  goes to Grok or runs locally; the hovered tile grows.
- After you let go, the tile shows "reading…", then either a green
  "sent N items" or a red "not sent". The tile's corner light then follows the
  run. Dropping outside every tile tells you nothing was sent.

**Local runs are always confirmed.** The module prompt is never executed as a
shell command. Only a command you type into the confirmation dialog is run
(with `/bin/zsh`), and only after you confirm it.

### Deadlines and the DDL energy bar

- There is **one** energy bar above the quick actions. Every unfinished deadline
  is a cell inside that bar rather than a bar of its own.
- The bar's color follows how many cells it holds: **3 or fewer is green, 4 to 6
  is orange, 7 or more is red**.
- Each cell drains from the moment it was added until it is due (the drain
  window is clamped between 1 hour and 14 days).
- Hover the bar to expand the list: click an entry to edit it, click the circle
  to mark it done, click × to delete it, or clear all completed entries at once.
- Add a deadline by typing in the field below the list, for example
  「周五 18:00 交实验报告」 ("Fri 18:00 hand in lab report"), 「明天下午3点 组会」
  ("tomorrow 3 pm group meeting"), or 「3小时后 开会」 ("meeting in 3 hours").
  The parser shows what it recognized, and you can adjust the date and time with
  the date picker.
- Supported expressions include today / tomorrow / the day after, weekdays and
  "next" weekdays, month/day dates, relative offsets ("in N days / hours /
  minutes"), and clock times with morning / afternoon / evening words. A date
  without a time defaults to 23:59; a time without a date means today, or
  tomorrow if that time has already passed.

### Ask Grok via Cursor Cloud Agents

Grok answers come from a Grok model running as a **Cursor Cloud Agent that is not
attached to any repository**. For every Grok request the app:

1. Creates an agent with `POST /v1/agents` on the Cursor API, using your Grok
   model ID (or the first Grok model listed by `/v1/models` if you left it
   empty).
2. Polls the run until it finishes (up to 20 minutes) and shows progress on the
   island.
3. Shows the Markdown answer on the island, where you can copy it or open the
   Cloud Agent in Cursor to keep the conversation going. Cancelling a run on the
   island also cancels the cloud run.

What gets sent:

- Up to 5 images (PNG, JPEG, GIF, WebP, 15 MB each) are attached as images.
- UTF-8 text files up to 120 KB are inlined into the prompt.
- Links are passed as URLs. Folders are mentioned by name only, since the agent
  cannot see your disk.
- The prompt tells the agent this is a Q&A: it must not modify repositories or
  open branches or pull requests.

**Quick actions.** The expanded island has three buttons — 整理错题 (organize
mistakes into a review sheet), 解答题目 (solve the problems on screen), and
检查代码 (review the code on screen) — plus a free-form **问 Grok** ("Ask Grok")
field. Each one:

- Captures a screenshot of the frontmost window (never the island itself).
- If the frontmost app is a supported browser (Safari, Chrome, Edge, Brave, Arc,
  Vivaldi, Opera), also reads the current tab's URL.
- Sends both to Grok with a task-specific prompt.

### Cursor agent and PR status lights

- The island polls your **Cursor Cloud Agents** (`GET /v1/agents`) and the
  **open pull requests** of a configured repository, every 20 seconds while
  something is running and every 60 seconds when idle.
- Every island run (Grok or Local), active Cloud Agent, and open PR gets its own
  light. Queued and running tasks breathe, finished tasks turn green, failed
  tasks turn red, and recently finished tasks stay visible for about 90 seconds.
  The header status dot turns orange when a PR's CI is failing.
- The island border blinks when a task starts or finishes.
- Click a light to see the list. Island runs open their result; Cloud Agents and
  PRs open in the browser.
- Pull requests are read with the locally signed-in `origin` CLI (looked up in `~/.local/bin`, `/opt/homebrew/bin`, and `/usr/local/bin`).
  PRs whose changes are already fully in `main` are not counted.

### Run records

- The **运行记录** ("Run records") page lists every run, with a filter to show
  only Grok answers.
- **清理已完成** ("Clear finished") removes all succeeded, failed, and cancelled
  records in one click. **选择** ("Select") enables multi-select delete; each row
  also has a trash button and a context menu. Deleting a running record cancels
  it first.
- Records persist across restarts, so Grok answers are still there after you
  reopen the app. Runs that were still in progress when the app quit are marked
  as interrupted.
- The "上次：…" ("Last: …") line on the home view reopens the most recent Grok
  answer.

---

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15 or later
- For Grok answers and Cloud Agent status: a Cursor account and a Cursor API key
- Optional, for PR status: the `origin` CLI installed and signed in

---

## Build and run with Xcode

1. Clone the repository and open the project at the repository root:

   ```bash
   git clone <repository-url> GrokIsland
   cd GrokIsland
   open GrokIsland.xcodeproj
   ```

   Finder shows `GrokIsland.xcodeproj` as a single file. If the project file is
   missing (for example, you only have the sources), regenerate it first:

   ```bash
   ./scripts/bootstrap-xcodeproj.sh
   ```

2. Select the **GrokIsland** scheme with **My Mac** as the destination and press
   **Run** (⌘R).

To build from the command line instead:

```bash
xcodebuild -scheme GrokIsland -configuration Debug -destination 'platform=macOS' build
```

### Desktop shortcut

To launch the app without Xcode, click the shortcut button in the island header,
or run this on your Mac:

```bash
./scripts/make-desktop-shortcut.sh
```

Both copy the app to `~/Applications/grok岛.app` and put a Finder alias named
`grok岛` on your Desktop. The script also builds the Debug app first.

---

## Configuration

Open the settings pane with the **gear** button on the island.

| Setting | Purpose |
| --- | --- |
| **Cursor API key** | Used to ask Grok and to read Cloud Agent status. Create one at [cursor.com/dashboard/api](https://cursor.com/dashboard/api), paste it in, and click Save. You can clear it at any time. |
| **Grok model ID** | Leave empty to automatically pick a Grok model from `/v1/models`, or enter a specific model ID. |
| **PR repository** | The `owner/name` repository whose open PRs drive the PR lights. Defaults to `leowang142857/GrokIsland`. |
| **Screen Recording** | Shows whether the permission is granted, with a shortcut to System Settings. |
| **Island background** | The expanded island's backdrop. Default is the built-in aurora glass; you can switch to solid color, gradient (presets or custom stops/angle), or an image from disk (with blur). Click **默认** ("Default") anytime to return to aurora while keeping your custom colors and image for later. |

Without an API key, modules, deadlines, and Local runs still work; Grok requests
fail with a prompt to add a key, and the Cloud Agent section shows that no key
is set.

### Island background details

- **Darken** lays a veil over the backdrop so white text and neon edges stay
  readable. Bright backgrounds raise the minimum veil automatically (images at
  least 18%), and Settings shows a hint when that happens.
- **Opacity** lets the glass beneath show through when lowered. **Aurora overlay**
  softly stacks the flowing aurora on a custom backdrop (set to 0 for a still
  background).
- Changes apply immediately; the island behind the settings pane is the live
  preview. **全部重置** ("Reset all") restores the default background and clears
  custom colors and the copied image.
- Chosen images are copied into
  `~/Library/Application Support/GrokIsland/backgrounds/` so the original can
  move or be deleted later; switching images removes the previous copy. Other
  options live in UserDefaults (`islandBackground`). The collapsed peek strip
  always keeps the aurora look.

---

## Privacy, permissions, and secrets

- **No secrets live in this repository.** The app never ships with an API key.
  Your Cursor API key is entered at runtime and stored only on your Mac, in
  `~/Library/Application Support/GrokIsland/cursor-api-key` with `0600`
  permissions. It is sent only to `api.cursor.com` as a bearer token.
- The key is stored in a file rather than the login Keychain because ad-hoc
  signed development builds get a new code identity on every rebuild, which
  would trigger a Keychain prompt each time.
- Please do not commit API keys, tokens, or personal data files. If you fork the
  project, keep credentials out of source, build settings, and test fixtures.
- **Screen Recording** is requested the first time you use a quick action, so the
  app can capture the frontmost window. Restart the app after granting it.
- **Automation (Apple Events)** is requested the first time the app reads a
  browser's current URL.
- Accessibility and Input Monitoring are **not** requested.
- The app is not sandboxed and uses the outgoing network client entitlement.
- Content you send to Grok (screenshots, URLs, inlined files, your prompt) goes
  to Cursor's Cloud Agents API and appears as a Cloud Agent in your Cursor
  account.

---

## Where data is stored

Everything is kept locally under `~/Library/Application Support/GrokIsland/`:

| File | Contents |
| --- | --- |
| `function-modules.json` | Your modules |
| `deadlines.json` | Your deadlines |
| `run-journal.json` | Run records, including Grok answers |
| `backgrounds/` | Copies of custom island background images |
| `cursor-api-key` | Your Cursor API key (`0600`) |

The Grok model ID and PR repository are stored in the app's user defaults.

---

## Headless core and tests (macOS or Linux)

The app itself needs macOS and Xcode, but the `GrokIslandCore` package — module
storage, drop intake, the run state machine, executors, the Cursor API client,
deadline parsing, and activity monitoring — builds without a UI. Its XCTest
suite runs on macOS and on Linux.

```bash
swift build   # builds GrokIslandCore
swift test    # runs the core test suite
```

`Combine` is Apple-only, so on other platforms the core uses
[OpenCombine](https://github.com/OpenCombine/OpenCombine) for
`ObservableObject` and `@Published` (guarded by `#if canImport(Combine)`); macOS
keeps using Combine.

A Cursor Cloud Agent environment is defined in `.cursor/` (`environment.json`
plus a `Dockerfile` based on the official `swift:6.0.3-noble` image), so agents
can build and test the core headlessly.

---

## Architecture

The UI talks to a single facade, **`IslandEngine`** (its surface is described by
the `IslandEngineAPI` protocol). The services underneath can be used and tested
on their own.

| Type | Role |
| --- | --- |
| `IslandEngine` | Facade: module CRUD, drop intake, run / confirm / cancel, Grok quick actions, record cleanup |
| `ModuleStore` | JSON persistence and CRUD for `FunctionModule` |
| `ResourceInbox` / `ResourceIntake` | Dropped files, folders, and URLs as references (no file copies) |
| `ExecutionRouter` | Dispatches runs to the Grok Bot or Local executor |
| `RunJournal` | Run state machine, progress, and optional JSON persistence |
| `LocalExecutor` | Opens files and runs a *confirmed* shell command |
| `GrokBotExecutor` / `GrokBotClient` | Grok executor facade; the app injects `CursorAgentGrokClient` |
| `CursorCloudAPI` / `CursorAgentGrokClient` | Minimal Cursor Cloud Agents API v1 client, and the Grok client built on it |
| `CloudActivityMonitor` | Polls Cloud Agents (Cursor API) and open PRs (`origin` CLI) |
| `TaskLightBoard` | One light per run, Cloud Agent, and PR |
| `DeadlineStore` / `DeadlineParser` | Deadline persistence, free-text due-date parsing, energy and urgency |
| `IslandSettings` / `IslandSettingsStorage` | API key file, Grok model ID, PR repository |
| `IslandBackgroundStyle` | Expanded-island background (aurora / solid / gradient / image) and its readability veil; persisted by `IslandSettingsStorage` |

### Typical calls

```swift
try engine.createModule(name: "Translate", prompt: "Translate into English", executor: .grokBot)
engine.ingestDroppedURLs(urls)                  // or ingestDropProviders(_:assignTo:completion:)
try engine.assignInbox(to: moduleID)            // requires at least one dropped item
try engine.confirmPendingLocal(openAttachedFiles: true, shellCommand: "")
try engine.quickAskGrok("Summarize these materials")
engine.cancelRun(id: runID)
engine.clearFinishedRuns()                      // returns the number removed
engine.deleteRuns(ids: selectedIDs)             // cancels active runs first
```

### Run state machine

`queued` → (`awaitingConfirmation` for Local) → `running` → `succeeded` | `failed` | `cancelled`

Terminal phases are sticky: a cancelled run cannot be overwritten by a late
success.

### Models

- `FunctionModule` — a user-created module (name, prompt, `ExecutorKind`)
- `ResourceItem` — a reference only (location, kind, optional UTI / size / bookmark)
- `ExecutorKind` — `grokBot` or `local`
- `RunRecord` / `RunPhase` — progress and result of one run
- `DeadlineItem` — one deadline entry

The app registers the `grok-island://` URL scheme, which is reserved for future
callbacks. Files opened with the app are added to the drop inbox.

---

## Project layout

```
GrokIsland.xcodeproj          # macOS app project (open this)
Package.swift                 # GrokIslandCore library + tests
GrokIsland/
  GrokIslandApp.swift         # @main and AppDelegate
  IslandPanel.swift           # NSPanel host, hover reveal / retract, peek strip
  PeekStrip.swift             # collapsed peek strip, collapse lock, notch hug
  IslandChrome.swift          # glass backdrop, colors, animations
  IslandBackground.swift      # custom island background style, presets, veil
  ShellView.swift             # expanded island: header, layers, module grid
  ActivityViews.swift         # task lights and activity list
  DeadlineViews.swift         # DDL energy bar
  GrokViews.swift             # quick actions, run detail, settings pane
  BackgroundViews.swift       # settings section for the island background
  RecordViews.swift           # run records (filter, clear, multi-select delete)
  PageCapture.swift           # frontmost-window screenshot and browser URL
  DesktopShortcut.swift       # ~/Applications copy + Desktop alias
  IslandEngine.swift          # facade used by the UI
  Models.swift, RunModels.swift
  ModuleStore.swift, ResourceInbox.swift, ResourceIntake.swift
  ExecutorProtocol.swift, ExecutionRouter.swift
  LocalExecutor.swift, GrokBotExecutor.swift
  CursorCloudAPI.swift        # Cursor Cloud Agents API + Grok client
  CloudActivity.swift         # Cloud Agent / PR polling via origin CLI
  GrokQuickActions.swift      # quick-action prompts
  RunJournal.swift            # persisted run records
  TaskLights.swift            # per-task lights
  Deadlines.swift             # deadline store, parser, energy
  IslandSettings.swift        # API key file and preferences
Tests/GrokIslandCoreTests/    # XCTest suite for GrokIslandCore
scripts/
  bootstrap-xcodeproj.sh      # regenerate GrokIsland.xcodeproj
  make-desktop-shortcut.sh    # build and add a Desktop alias
  generate-app-icon.py        # app icon generator
.cursor/                      # Cloud Agent environment (Linux, headless core)
```

---

## Contributing

Issues and pull requests are welcome.

- Keep UI code thin and put logic in `GrokIslandCore` so it stays testable.
- Run `swift test` before opening a pull request, and build the app in Xcode if
  you touched UI files.
- If you add a Swift file to the app, add it to `GrokIsland.xcodeproj` and to
  `scripts/bootstrap-xcodeproj.sh`. If it depends on AppKit or SwiftUI, also add
  it to the `exclude` list in `Package.swift`.
- Never commit API keys or other credentials.

No license file has been added yet.
