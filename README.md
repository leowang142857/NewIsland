# grok岛 / Grok Island

Native macOS app (SwiftUI + AppKit). A floating panel at the top of the screen that accepts dropped files / folders / URLs and runs them through **user-created function modules**.

Modules are persistent skills you define (e.g. 翻译, 整理笔记, 跑脚本) — not auto-split task chunks.

The current window is a **minimal functional shell** so the backend can be used and iterated on. Island chrome, glass, and animations are intentionally not built.

---

## 打开 / 构建 / 运行（中文）

1. 在 Mac 上安装 Xcode 15+（macOS 14+）。
2. 打开工程：

```bash
open GrokIsland.xcodeproj
```

3. 选择 scheme **GrokIsland**，目标为本机 Mac，点 Run（⌘R）。
4. 或命令行：

```bash
xcodebuild -scheme GrokIsland -configuration Debug -destination 'platform=macOS' build
```

首次运行后，屏幕上方会出现功能面板。

**试用：**

- 点 **Create module** 建一个模块（名称 + 提示词 + Grok Bot / Local）。空列表文案：创建你的第一个功能模块。
- 或点 **Demo** 载入三个演示模块。
- 把文件 / 文件夹 / 链接拖进面板。
- 选中模块，点 **Run selected module**。
- Local 模块会先弹出确认，不会把提示词当成 shell；只有你在确认框里填写并确认的命令才会执行。
- Grok Bot 目前是演示桩（进度 + 假结果），没有 API key。

模块保存在：

`~/Library/Application Support/GrokIsland/function-modules.json`

---

## Open / build / run (English)

1. Xcode 15+ on macOS 14+.
2. `open GrokIsland.xcodeproj` or the `xcodebuild` command above.
3. Run the **GrokIsland** scheme.

**Try the backend:** create or load demo modules → drop files onto the panel → select a module → run. Local execution requires an explicit confirmation. Grok Bot is a stub with a documented hook for later wiring.

---

## Architecture

UI should call **`IslandEngine`** only. Services underneath are independently usable.

| Type | Role |
| --- | --- |
| `IslandEngine` | Facade: module CRUD, inbox intake, run / confirm / cancel, quick ask |
| `ModuleStore` | JSON persistence + CRUD for `FunctionModule` |
| `ResourceInbox` | In-memory references to dropped files / folders / URLs |
| `ResourceIntake` | Pasteboard / URL → `ResourceItem` metadata (no file copies) |
| `ExecutionRouter` | Grok vs Local dispatch + run tasks |
| `RunJournal` | Run state machine + progress / notifications |
| `LocalExecutor` | Open files and/or a *confirmed* zsh command |
| `GrokBotExecutor` | Stub + `GrokBotTransport` placeholders |

### Run state machine

`queued` → (`awaitingConfirmation` for Local) → `running` → `succeeded` | `failed` | `cancelled`

### Models

- `FunctionModule` — user-created function (name, prompt/config, `ExecutorKind`)
- `ResourceItem` — reference only (`location`, kind, optional UTI / size / bookmark)
- `ExecutorKind` — `grokBot` | `local`
- `RunRecord` / `RunPhase` — notification + progress
- `IslandState` — reserved for a future island frontend

### Grok Bot wiring (later)

See `GrokBotExecutor.swift`:

- URL scheme: `grok-island://run?module=…`
- HTTP placeholder: `http://127.0.0.1:8787/v1/run`
- Do **not** add API keys in this target.

### Frontend TODOs

`IslandPanel.swift` and `ShellView.swift` are marked `TODO(frontend)`. Replace the shell with the island UI; keep calling `IslandEngine`.

Accessibility / Input Monitoring is **not** requested. Standard drop onto the panel is enough.

---

## Layout

```
GrokIsland.xcodeproj
GrokIsland/
  GrokIslandApp.swift      # @main + AppDelegate
  IslandPanel.swift        # NSPanel host (thin)
  ShellView.swift          # functional shell
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
```
