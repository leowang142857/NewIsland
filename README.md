# grok岛 / Grok Island

Native macOS app (SwiftUI + AppKit). A top-of-screen panel that accepts dropped files / folders / URLs and runs them through **user-created function modules**.

Modules are persistent skills you define (e.g. 翻译, 整理笔记, 跑脚本) — not auto-split task chunks.

The window is a **minimal functional shell** so the backend can be exercised. Island chrome and glass are intentionally not built (`TODO(frontend)`).

The panel stays docked at the top center (not freely draggable). **Only hovering the collapsed peek strip** shows it; moving away auto-retracts. Pin it from the header if you want it to stay open. Uses `NSEvent.mouseLocation` (no Accessibility permission).

To put a launcher on the Desktop: click the header shortcut button, or run `./scripts/make-desktop-shortcut.sh` on a Mac. That copies the app to `~/Applications/grok岛.app` and creates a Finder alias `~/Desktop/grok岛`.

Default view is a grid of module tiles plus a **新建模块** button. Click a tile to edit it; **drop resources onto a tile** to run that module on them.

---

## 打开 / 构建 / 运行（中文）

这是云端新建的项目：代码在 Agent 仓库里，**不会自动出现在你电脑上的旧文件夹**。本地要先有完整仓库：

1. 在本 Agent 页面点 **Create repo**，创建一个 GitHub / Origin 仓库。
2. 在 Mac 上 clone **那个新仓库**（不要打开你之前的空目录）。
3. 根目录应同时有 `GrokIsland/`（源码）和 `GrokIsland.xcodeproj`（Xcode 工程包）。Finder 里 `.xcodeproj` 显示成一个文件，不是文件夹。

只有源码、没有工程文件时，在仓库根目录执行：

```bash
./scripts/bootstrap-xcodeproj.sh
```

然后：

1. 安装 Xcode 15+（macOS 14+）。
2. 打开工程：

```bash
open GrokIsland.xcodeproj
```

3. 选择 scheme **GrokIsland**，目标为本机 Mac，点 Run（⌘R）。
4. 或命令行：

```bash
xcodebuild -scheme GrokIsland -configuration Debug -destination 'platform=macOS' build
```

核心逻辑的单测（不启动 UI）：

```bash
swift test
```

**面板：** 默认上提成细条；只有鼠标碰到这条细边框才会滑下来。移开约 0.5 秒后自动上提。确认 Local 运行或点「钉住」时不会收起。

**桌面快捷方式：** 展开后面板标题栏的方块箭头按钮，或在仓库根目录执行 `./scripts/make-desktop-shortcut.sh`。桌面会出现「grok岛」。

**试用后端：**

- 点 **新建模块** 建一个模块（名称 + 提示词 + Grok Bot / Local）。空列表文案：创建你的第一个功能模块。
- 或点 **载入示例** 载入三个演示模块（仅当列表为空）。
- 点方块进入编辑 / 删除。
- 把文件 / 文件夹 / 链接**拖到某个模块方块上**，即用该模块执行（`IslandEngine.ingestDropProviders(_:assignTo:)`）。
- Local 模块会先确认：提示词不会当 shell；只有确认框里填写的命令才会执行。
- Grok Bot 目前是演示桩（进度 + 假结果），没有 API key。

模块保存在：

`~/Library/Application Support/GrokIsland/function-modules.json`

---

## Open / build / run (English)

This started as a cloud new-project session. Create a repo with the **Create repo** pill, clone **that** repo to your Mac, then open `GrokIsland.xcodeproj` at the repo root (Finder shows it as a single file). If you only have sources:

```bash
./scripts/bootstrap-xcodeproj.sh
open GrokIsland.xcodeproj
```

1. Xcode 15+ on macOS 14+.
2. `open GrokIsland.xcodeproj` or the `xcodebuild` command above.
3. Run the **GrokIsland** scheme.

**Exercise the backend:** create or load demo modules → drop files onto the panel → select a module → run. Local execution requires explicit confirmation. Grok Bot is a stub with a documented hook for later wiring.

---

## Public API (call these from UI)

The thin UI should talk to **`IslandEngine`** (see `IslandEngineAPI`). Services underneath are independently usable and testable.

| Type | Role |
| --- | --- |
| `IslandEngine` | Facade: module CRUD, inbox intake, assign/run/confirm/cancel, quick ask |
| `ModuleStore` | JSON persistence + CRUD / rename for `FunctionModule` |
| `ResourceInbox` | In-memory references to dropped files / folders / URLs |
| `ResourceIntake` | Pasteboard / URL → `ResourceItem` metadata (no file copies) |
| `ExecutionRouter` | Grok vs Local dispatch + run tasks |
| `RunJournal` | Run state machine + progress / notifications |
| `LocalExecutor` | Open files and/or a *confirmed* zsh command |
| `GrokBotExecutor` | Forwards to a `GrokBotClient` (demo stub by default) |

### Typical UI calls

```swift
try engine.createModule(name: "翻译", prompt: "译成中文", executor: .grokBot)
engine.ingestDroppedURLs(urls)                 // or ingestDropProviders(_:)
try engine.assignInbox(to: moduleID)           // requires inbox items
try engine.confirmPendingLocal(openAttachedFiles: true, shellCommand: "")
try engine.quickAskGrok("总结这些材料")
engine.cancelRun(id: runID)
```

### Run state machine

`queued` → (`awaitingConfirmation` for Local) → `running` → `succeeded` | `failed` | `cancelled`

Terminal phases are sticky (a cancelled run cannot be overwritten by a late success).

### Models

- `FunctionModule` — user-created function (name, prompt/config, `ExecutorKind`)
- `ResourceItem` — reference only (`location`, kind, optional UTI / size / bookmark)
- `ExecutorKind` — `grokBot` | `local`
- `RunRecord` / `RunPhase` — notification + progress
- `IslandState` — reserved for a future island frontend

### Grok Bot wiring (later)

See `GrokBotExecutor.swift`:

- Inject a `GrokBotClient` (demo: `DemoGrokBotClient`, unused HTTP: `HTTPGrokBotClient`)
- Wire payload: `ExecutionRequest.grokWirePayload()` (`GrokBotWireRequest`)
- URL scheme: `grok-island://run?module=…`
- HTTP placeholder: `http://127.0.0.1:8787/v1/run`
- Do **not** add API keys in this target.

### Frontend TODOs

`IslandPanel.swift` and `ShellView.swift` are marked `TODO(frontend)`. Replace the shell with the island UI; keep calling `IslandEngine`.

Accessibility / Input Monitoring is **not** requested. Standard drop onto the panel is enough.

---

## Layout

```
GrokIsland.xcodeproj          # app (open this)
Package.swift                 # GrokIslandCore + tests
GrokIsland/
  GrokIslandApp.swift         # @main + AppDelegate
  IslandPanel.swift           # NSPanel host (thin)
  ShellView.swift             # functional shell
  Models.swift
  RunModels.swift
  ModuleStore.swift
  ResourceInbox.swift
  ResourceIntake.swift
  ExecutorProtocol.swift
  LocalExecutor.swift
  GrokBotExecutor.swift
  RunJournal.swift
  ExecutionRouter.swift
  IslandEngine.swift
Tests/GrokIslandCoreTests/
```
