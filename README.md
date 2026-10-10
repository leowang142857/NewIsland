# NewIsland

NewIsland is a top-of-screen work island for Mac: deadlines, focus, and Ask Grok sit in one strip under the notch, so you don't switch windows. Mac 上的灵动岛，把今天要做的事和问 Grok 放在屏幕最上面。 Keywords: Mac Dynamic Island, macOS menu bar island, notch productivity, deadline focus timer, ask Grok on Mac, 灵动岛 Mac, 顶部任务条, 截止日期 专注计时.

Maintained by [@leowang142857](https://github.com/leowang142857).

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
  (pin button in the header), while you drag something over it, while you drag
  files out of the staging tray, and while a Local run is waiting for your
  confirmation.
- A **collapse lock** sits at the left end of the peek strip. Click it (it turns
  amber) to keep the island collapsed even when the pointer is over the strip or
  you drag files across it; click again to unlock. Hovering the lock itself does
  not expand the island, so you can always reach it. The lock state is remembered
  across launches.
- **The menu bar is never covered.** The strip and the island both hang below
  it, so every menu and status item stays visible and clickable, and pointing at
  the menu bar never opens the island.
- The peek strip is a 22 pt pill hanging from the bottom of the menu bar. On
  Macs with a notch it is exactly as wide as the notch (macOS reports the width)
  and sits right under it, so it reads as the camera's shadow. On screens
  without a notch it is 164 pt wide, centered under the menu bar.
- The expanded island is a wide, short panel that opens 6 pt below the menu bar,
  centered under the notch: **900 × 300 pt, three times as wide as it is tall**.
  On a screen narrower than 932 pt it keeps 16 pt from each side, and when the
  screen is too short for 300 pt it stops 12 pt above the Dock (or the bottom of
  the screen). It never gets smaller than 720 × 272 pt. The numbers live in
  `IslandShell` (`PeekStrip.swift`).
- Hover detection polls `NSEvent.mouseLocation`, so no Accessibility or Input
  Monitoring permission is needed.

The header is one row across the island: the status light and name (click for
Cloud Agent and PR activity), then on home one **task light** per running or
recently finished task (they scroll sideways when there are more than fit), then
what is running, or the time when nothing is, then the **gear** (Settings) and
the **pin**.

Under the header, home is two columns split by a hairline:

- **Left (280 pt): deadlines and Grok.** The **DDL energy bar** with all open
  deadlines in one bar, then the **Grok quick actions**: three one-tap tiles, an
  "Ask Grok" field, a split-task field, and the line that reopens the last answer.
- **Right: modules / staging tray / records.** Three tabs (模块, 暂存, 记录) over
  your module grid, the files you parked on the island, or the history of runs.

The other pages use the width the same way: the module editor puts the name and
executor beside the prompt, a run you asked about shows your question beside the
answer, Cloud Agents and PRs sit side by side, and Settings has three columns.

### Look and feel

The island follows macOS Control Center rather than a dashboard:

- One dark frosted panel. Content sits on soft **platters** a step lighter than
  the panel, edged with hairlines rather than shadows. The window casts a shadow
  only while the island is open.
- Corners nest: the island's 24 pt corners sit 12 pt outside 12 pt platters, and
  the send buttons are concentric with their capsule fields.
- Controls are capsules and circles with clear targets (26 pt for header
  glyphs): a white **prominent** capsule for the one main action in view, quiet
  capsules for secondary ones, and red only for destructive ones. Segmented
  controls slide a raised thumb between options.
- Color carries meaning only: blue for what you're interacting with, and green,
  amber, orange, and red for task states. Everything else is white at some
  opacity, so custom backgrounds still look calm.
- Copy is short, plain Chinese.

Design tokens and the shared button styles live in `IslandChrome.swift`.

When collapsed, the peek strip shows the collapse lock on the far left, then up
to three task lights (two lights plus a count when there are more), and on the
right the countdown of the next deadline when it is due within three days or
overdue. Without a notch, the name sits between them.

### Modular island (function modules)

Modules are persistent, user-defined skills — not automatically generated task
chunks. Each module has a name, a prompt, and an executor:

| Executor | What it does |
| --- | --- |
| **Grok Bot** | Sends the prompt and the dropped resources to the model provider chosen in Settings (xAI, OpenAI, DeepSeek, Anthropic / Claude, local Ollama, an OpenAI-compatible endpoint, or Cursor Cloud Agents). |
| **Local** | Runs on your Mac: optionally opens the dropped files, and optionally runs a shell command that you type and confirm. |

How to use them:

- Click **新建模块** ("New module") to create one. With an empty list you can
  also click **先放几个示例** ("Add a few examples") to add three demo modules: 翻译
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

### Staging tray (暂存)

The **暂存** ("Staging") tab is a shelf for files you want off the Desktop for
now: park them on the island, sort them into folders, and drag them back out
when you need them.

- **Drag files or folders in.** Drop them on the tray list, on the 暂存 tab, or,
  while dragging over the modules, on the **或者先放进暂存区** ("or park it in
  the tray") slot under the grid. Hold a drag on the 暂存 tab for a moment and
  the tray opens, like a spring-loaded Finder folder.
- **Moved or copied, as in Finder.** By default a file from the same disk is
  moved into the tray, so it leaves the Desktop; from another disk it is copied.
  Hold ⌥ while dropping to do the opposite once, or change the default in the
  tray's **⋯** menu (移进来，原处不留 "move in" / 拷贝一份，原文件不动 "copy").
  If an original can't be moved (locked, or macOS refuses), the tray keeps a
  copy and says the original stayed where it was.
- **Files from other apps.** A file dragged out of an app like WeChat often
  still sits inside that app's private container, which macOS doesn't let other
  apps open. The tray asks the app for its own copy (its file representation or
  file promise) and copies that in; it never moves such a file. If the app
  hands nothing over, the tray says 来源 App 没交出可读文件（微信等）。请先存到桌面/文件夹，再拖进暂存
  ("the app didn't hand over a readable file; save it to the Desktop or a
  folder first, then drag it in").
- **Nothing is overwritten.** A second `报告.pdf` arrives as `报告 2.pdf`.
- **Organize inside.** Make a folder with the folder-plus button and name it in
  place. Double-click a folder to open it and use the breadcrumb to go back;
  double-click a file to open it in its default app. Drag rows onto a folder or a
  breadcrumb to move them, or use **移到…** ("Move to…") to pick any folder.
  **归入新文件夹** ("Group into new folder") gathers the selection into a fresh
  folder. Rename from the right-click menu.
- **Multi-select** like Finder: click, ⌘-click to toggle, ⇧-click for a range,
  or **全选** ("Select all") in the ⋯ menu.
- **Delete** moves items to the macOS Trash after a one-line confirmation, so
  they can be put back.
- **Drag back out to reclaim.** Drag a row, or the whole selection, to the
  Desktop or a Finder window. On the same disk Finder moves it out of the tray,
  and the tray says how many came back; hold ⌥ in Finder to leave a copy in the
  tray. The island stays open until the drag ends.
- The tray is a real folder, `~/Library/Application Support/GrokIsland/tray/`,
  and that folder is all of its state: it survives relaunches, and whatever you
  put there from Finder (**⋯ → 在 Finder 中显示** "Show in Finder") shows up in
  the tray.

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

### Ask Grok

Ask Grok, the three shortcut buttons, and split-task all use the **model service**
selected in Settings. A Cursor account is not required.

| Service | What you need |
| --- | --- |
| **xAI (Grok)** | An API key from [console.x.ai](https://console.x.ai/). Default model `grok-4.6`, which accepts screenshots. |
| **OpenAI** | An API key from [platform.openai.com/api-keys](https://platform.openai.com/api-keys). Default model `gpt-4o`. |
| **DeepSeek** | An API key from [platform.deepseek.com](https://platform.deepseek.com/api_keys). Default model `deepseek-flash`, which accepts screenshots. |
| **Anthropic (Claude)** | An API key from [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys) (`sk-ant-…`). Default model `claude-sonnet-5-5`. Calls the Messages API, and accepts screenshots. |
| **Local Ollama** | Ollama running on your Mac. Default address `http://127.0.0.1:11434/v1`. No API key. Type a model name (a vision model if you want the shortcut screenshots to be read). |
| **OpenAI-compatible** | Any endpoint that speaks chat completions: base URL, API key, and model name. |
| **Cursor (advanced)** | A Cursor API key. Answers run as a Cloud Agent with no repository attached. |

xAI, OpenAI, DeepSeek, Ollama, and OpenAI-compatible endpoints use one
OpenAI-style `POST /chat/completions` request. Claude uses Anthropic's Messages
API (`POST /v1/messages`) with the key in `x-api-key`. Shortcut buttons attach
the frontmost-window screenshot as an image. If the chosen model cannot take
images, the run fails with a clear message and the screenshot is not silently dropped.

**Cursor Cloud Agents** remain available from the same provider menu. In that mode
the app still creates a no-repo agent with `POST /v1/agents`, polls until it
finishes, and can open the agent in Cursor. Cancelling a run on the island also
cancels the cloud run. Leave the Grok model ID empty to pick a Grok model from
`/v1/models`.

**Split-task** breaks one job into 2–4 pieces, runs them in parallel, then writes
a combined summary. On a model API those steps are chat completions. On Cursor
they are cloud agents. Either way, each piece has its own task light, a failed
piece stays marked failed, and the other pieces are kept.

What gets sent:

- Up to 5 images (PNG, JPEG, GIF, WebP, 15 MB each) are attached as images.
- UTF-8 text files up to 120 KB are inlined into the prompt.
- Links are passed as URLs. Folders are mentioned by name only.
- The prompt says this is a Q&A: it must not modify repositories or open branches
  or pull requests.

**Quick actions.** The expanded island has three buttons — 整理错题 (organize
mistakes into a review sheet), 解答题目 (solve the problems on screen), and
检查代码 (review the code on screen) — plus a free-form **问 Grok** ("Ask Grok")
field. Each one:

- Captures a screenshot of the frontmost window (never the island itself).
- If the frontmost app is a supported browser (Safari, Chrome, Edge, Brave, Arc,
  Vivaldi, Opera), also reads the current tab's URL.
- Sends both to the selected model with a task-specific prompt.

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

- The **记录** ("Records") tab lists every run; switch **全部 / 回答** ("All /
  Answers") to show only Grok answers.
- **清掉已完成** ("Clear finished") removes all succeeded, failed, and cancelled
  records in one click. **选择** ("Select") enables multi-select delete; each row
  also has a trash button and a context menu. Deleting a running record cancels
  it first.
- Records persist across restarts, so Grok answers are still there after you
  reopen the app. Runs that were still in progress when the app quit are marked
  as interrupted.
- The "上次 …" ("Last …") line on the home view reopens the most recent Grok
  answer.

---

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15 or later
- For Ask Grok, the shortcut buttons, and split-task: an API key for xAI, OpenAI, DeepSeek, or Anthropic (Claude), a local Ollama, or any OpenAI-compatible endpoint. A Cursor account is optional.
- Optional, for Cloud Agent status: a Cursor API key
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

To launch the app without Xcode, open Settings (the gear) and click **放到桌面**
("Put on Desktop") under **其他** ("Other"), or run this on your Mac:

```bash
./scripts/make-desktop-shortcut.sh
```

Both copy the app to `~/Applications/NewIsland.app` and put a Finder alias named
`NewIsland` on your Desktop. The script also builds the Debug app first.

---

## Configuration

Open the settings pane with the **gear** button on the island. Settings are
grouped like System Settings: 模型 (model), PR 仓库 (PR repository), 权限
(permissions), 快捷按钮 (shortcut buttons), 岛背景 (island background), and 其他
(other).

| Setting | Purpose |
| --- | --- |
| **模型服务** ("Model service") | Which backend answers Ask Grok, the shortcut buttons, and split-task. Choose xAI, OpenAI, DeepSeek, Anthropic (Claude), local Ollama, an OpenAI-compatible endpoint, or Cursor (advanced). |
| **API key** | The key for the selected service. Paste it and click Save. You can clear it at any time. Ollama can be left blank. xAI keys come from [console.x.ai](https://console.x.ai/), OpenAI from [platform.openai.com/api-keys](https://platform.openai.com/api-keys), DeepSeek from [platform.deepseek.com/api_keys](https://platform.deepseek.com/api_keys), Anthropic from [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys), and Cursor from [cursor.com/dashboard/api](https://cursor.com/dashboard/api). |
| **模型** ("Model") | The model name. xAI defaults to `grok-4.6`, OpenAI to `gpt-4o`, DeepSeek to `deepseek-flash`, and Anthropic to `claude-sonnet-5-5`. Ollama and compatible endpoints need a name you type. For Cursor, leave the Grok model ID empty to pick one from `/v1/models`. |
| **接口地址** ("Base URL") | Shown for Ollama (default `http://127.0.0.1:11434/v1`) and for an OpenAI-compatible endpoint. |
| **PR repository** | The `owner/name` repository whose open PRs drive the PR lights. Defaults to `leowang142857/GrokIsland`. |
| **Screen Recording** | Shows whether the permission is granted, with a shortcut to System Settings. |
| **快捷按钮** ("Shortcut buttons") | What each of the three home tiles does: a built-in action, or your own title, prompt, and icon. **恢复默认** ("Restore defaults") brings back the three built-ins. |
| **Island background** | The expanded island's backdrop. Default is a quiet near-black frosted glass; you can switch to solid color, gradient (presets or custom stops/angle), or an image from disk (with blur). Click **默认** ("Default") anytime to return to it while keeping your custom colors and image for later. |
| **桌面快捷方式** ("Desktop shortcut") | Under 其他. **放到桌面** ("Put on Desktop") copies the app to `~/Applications` and puts an alias on your Desktop. |

The first launch asks you to pick a service and paste a key. It does not assume
Cursor. Modules, deadlines, and Local runs still work with nothing filled in;
Grok requests fail with a prompt to choose a service. An install that already
has a Cursor API key keeps using Cursor until you pick something else.

If you still keep a Cursor key, the Cloud Agent lights keep using it even when
answers go to another provider. Without that key, the Cloud Agent section shows
that no Cursor key is set.

### Island background details

- **Darken** lays a veil over the backdrop so white text stays
  readable. Bright backgrounds raise the minimum veil automatically (images at
  least 18%), and Settings shows a hint when that happens.
- **Opacity** lets the glass beneath show through when lowered. **Aurora overlay**
  softly stacks the old flowing aurora on a custom backdrop. It starts at 0 (a
  still background).
- Changes apply immediately; the island behind the settings pane is the live
  preview. **全部重置** ("Reset all") restores the default background and clears
  custom colors and the copied image.
- Chosen images are copied into
  `~/Library/Application Support/GrokIsland/backgrounds/` so the original can
  move or be deleted later; switching images removes the previous copy. Other
  options live in UserDefaults (`islandBackground`). The collapsed peek strip
  is always plain black so it blends into the notch.

---

## Privacy, permissions, and secrets

- **No secrets live in this repository.** The app never ships with an API key.
  Each provider key is entered at runtime and stored only on your Mac, as its own
  `0600` file under `~/Library/Application Support/GrokIsland/` (`cursor-api-key`,
  `xai-api-key`, `openai-api-key`, `deepseek-api-key`, `anthropic-api-key`,
  `ollama-api-key`, `compatible-api-key`). A key is sent only to that provider
  (a bearer token, or `x-api-key` for Anthropic) and is never written to logs.
- Keys are stored in files rather than the login Keychain because ad-hoc
  signed development builds get a new code identity on every rebuild, which
  would trigger a Keychain prompt each time.
- Please do not commit API keys, tokens, or personal data files. If you fork the
  project, keep credentials out of source, build settings, and test fixtures.
- **Screen Recording** is requested the first time you use a quick action, so the
  app can capture the frontmost window. Restart the app after granting it.
- **Automation (Apple Events)** is requested the first time the app reads a
  browser's current URL.
- Accessibility and Input Monitoring are **not** requested.
- **Files and Folders** access (Desktop, Documents, Downloads) may be requested
  the first time you move a file from one of those folders into the staging
  tray. A drop also hands over access to the dropped files themselves, and the
  tray holds on to it until they are moved or copied in. If only the move is
  refused, the tray copies the file and leaves the original in place. If macOS
  refuses even reading it, the tray says so and names the setting
  (**系统设置 → 隐私与安全性 → 文件与文件夹**, System Settings → Privacy &
  Security → Files and Folders) instead of a bare 没有权限 ("no permission").
  That setting does not cover files inside another app's container
  (`~/Library/Containers/…`, e.g. a PDF dragged out of WeChat); for those the
  tray asks the source app for a copy, and otherwise points you to saving the
  file somewhere ordinary first.
- The app is not sandboxed and uses the outgoing network client entitlement.
- Content you send (screenshots, URLs, inlined files, your prompt) goes to the
  provider you selected. With Cursor selected, it also appears as a Cloud Agent
  in your Cursor account.

---

## Where data is stored

Everything is kept locally under `~/Library/Application Support/GrokIsland/`:

| File | Contents |
| --- | --- |
| `function-modules.json` | Your modules |
| `deadlines.json` | Your deadlines |
| `run-journal.json` | Run records, including Grok answers |
| `backgrounds/` | Copies of custom island background images |
| `tray/` | The staging tray: the parked files and folders themselves |
| `cursor-api-key` | Cursor API key (`0600`), if you use Cloud Agents |
| `xai-api-key` | xAI API key (`0600`) |
| `openai-api-key` | OpenAI API key (`0600`) |
| `deepseek-api-key` | DeepSeek API key (`0600`) |
| `anthropic-api-key` | Anthropic / Claude API key (`0600`) |
| `ollama-api-key` | Optional Ollama key (`0600`) |
| `compatible-api-key` | OpenAI-compatible API key (`0600`) |

The selected provider, model ids, Ollama or compatible base URL, PR
repository, and the tray's move-or-copy default (`trayDropMode`) are stored in
the app's user defaults. An older install with only
`cursor-api-key` and no provider choice keeps using Cursor.

---

## Headless core and tests (macOS or Linux)

The app itself needs macOS and Xcode, but the `GrokIslandCore` package — module
storage, drop intake, the run state machine, executors, the model-provider and
chat-completions clients, the Cursor API client, deadline parsing, activity
monitoring, and the staging tray's file operations — builds without a UI. Its XCTest
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
| `GrokBotExecutor` / `GrokBotClient` | Grok executor facade; the app injects `RoutedGrokClient` |
| `ModelProviderKind` / `IslandSettingsStorage` | Provider choice, per-provider API key files, model id, and base URL |
| `ChatCompletionClient` / `ChatCompletionGrokClient` | OpenAI-compatible chat completions, including image input |
| `AnthropicMessagesClient` | Anthropic Messages API (`POST /v1/messages`), including image blocks |
| `ChatSplitTaskOrchestrator` | Split-task planner, parallel subtasks, and summary as model calls |
| `CursorCloudAPI` / `CursorAgentGrokClient` | Cursor Cloud Agents API v1 client, and the Grok client built on it |
| `CloudActivityMonitor` | Polls Cloud Agents (Cursor API) and open PRs (`origin` CLI) |
| `TaskLightBoard` | One light per run, Cloud Agent, and PR |
| `DeadlineStore` / `DeadlineParser` | Deadline persistence, free-text due-date parsing, energy and urgency |
| `IslandSettings` / `IslandSettingsStorage` | Provider choice, API key files, model id, base URL, PR repository |
| `IslandBackgroundStyle` | Expanded-island background (default / solid / gradient / image) and its readability veil; persisted by `IslandSettingsStorage` |
| `FileTray` / `TrayFileSystem` | Staging tray: the folder being shown, Finder-style selection, and move / copy / rename / delete on the `tray/` folder, which is the only record kept |

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
  PeekStrip.swift             # peek strip and expanded island geometry, collapse lock
  IslandChrome.swift          # design tokens, platters, buttons, glass backdrop
  IslandBackground.swift      # custom island background style, presets, veil
  ShellView.swift             # expanded island: header, two-column home, module grid
  ActivityViews.swift         # task lights and activity list
  DeadlineViews.swift         # DDL energy bar
  GrokViews.swift             # quick actions, run detail, settings pane
  BackgroundViews.swift       # settings section for the island background
  RecordViews.swift           # run records (filter, clear, multi-select delete)
  FileTrayViews.swift         # staging tray tab, AppKit drag-out rows, drop targets
  PageCapture.swift           # frontmost-window screenshot and browser URL
  DesktopShortcut.swift       # ~/Applications copy + Desktop alias
  IslandEngine.swift          # facade used by the UI
  Models.swift, RunModels.swift
  ModuleStore.swift, ResourceInbox.swift, ResourceIntake.swift
  ExecutorProtocol.swift, ExecutionRouter.swift
  LocalExecutor.swift, GrokBotExecutor.swift
  CursorCloudAPI.swift        # Cursor Cloud Agents API + Grok client
  ModelProvider.swift          # Provider catalog, key files, image-input policy
  ChatCompletionAPI.swift      # OpenAI-compatible chat client, routing, model split-task
  AnthropicMessagesAPI.swift   # Anthropic Messages client (Claude)
  CloudActivity.swift         # Cloud Agent / PR polling via origin CLI
  GrokQuickActions.swift      # quick-action prompts
  RunJournal.swift            # persisted run records
  TaskLights.swift            # per-task lights
  Deadlines.swift             # deadline store, parser, energy
  FileTray.swift              # staging tray model and file operations
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
- Tray drop targets read the file URLs from the drag pasteboard inside the drop
  callback and pass them straight to `TrayDrop.accept`, which starts their
  security-scoped access and calls `FileTray.take` before the callback returns.
  Access is started on `TrayDropAccess.urls`, and those same values are what
  gets moved or copied; don't remap them (`standardizedFileURL`, `filePathURL`,
  a path round trip) in between. Don't cache them from hovering, load them later
  from an `NSItemProvider`, or start the transfer in a `Task` either: those URLs
  can lack the drop's access, and Desktop files then fail with "Operation not
  permitted".
- What the source app can hand over itself (pasteboard bytes, file promises)
  only exists during the drop, so `TrayDropSource` collects it in its `init`,
  inside the callback. `FileTray.take` asks it first for files in another app's
  container and again for anything the system refuses to copy; whatever an
  `NSItemProvider` file representation gives back must be copied in inside its
  completion handler, before the provider deletes it.
- Never commit API keys or other credentials.

No license file has been added yet.
