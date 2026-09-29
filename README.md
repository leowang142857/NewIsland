# grok岛 / Grok Island

Native macOS app (SwiftUI + AppKit). A top-of-screen panel that accepts dropped files / folders / URLs and runs them through **user-created function modules**.

Modules are persistent skills you define (e.g. 翻译, 整理笔记, 跑脚本) — not auto-split task chunks.

The window is a **minimal functional shell** so the backend can be exercised. Island chrome and glass are intentionally not built (`TODO(frontend)`).

The panel stays docked at the top center (not freely draggable). **Only hovering the collapsed peek strip** shows it; moving away auto-retracts. Pin it from the header if you want it to stay open; the lock at the left end of the peek strip does the opposite and keeps it collapsed even under the mouse. Uses `NSEvent.mouseLocation` (no Accessibility permission).

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

**锁定收起：** 细条最左边是一把锁。点一下锁上（琥珀色），鼠标悬停、拖文件经过都不会再展开；再点一下解锁，恢复悬停展开。鼠标停在锁上本身不会触发展开，所以没锁时也能点到它。锁定状态会记住，重开 app 后不变。

**桌面快捷方式：** 展开后面板标题栏的方块箭头按钮，或在仓库根目录执行 `./scripts/make-desktop-shortcut.sh`。桌面会出现「grok岛」。

**试用后端：**

- 点 **新建模块** 建一个模块（名称 + 提示词 + Grok Bot / Local）。空列表文案：创建你的第一个功能模块。
- 或点 **载入示例** 载入三个演示模块（仅当列表为空）。
- 点方块进入编辑 / 删除。
- 把文件 / 文件夹 / 链接**拖到某个模块方块上**，即用该模块执行（`IslandEngine.ingestDropProviders(_:assignTo:)`）。
- Local 模块会先确认：提示词不会当 shell；只有确认框里填写的命令才会执行。
- Grok Bot 模块通过 Cursor Cloud Agents API 开一个不绑仓库的 Agent，用 Grok 模型作答。拖进来的图片会作为图片附上，小文本文件会内联进提示词。

模块保存在：

`~/Library/Application Support/GrokIsland/function-modules.json`

**设置（齿轮）：** 填 Cursor API key（[cursor.com/dashboard/api](https://cursor.com/dashboard/api)）。key 只存在本机 `~/Library/Application Support/GrokIsland/cursor-api-key`（权限 600）。Grok 模型 ID 留空时，会从 `/v1/models` 自动选一个 Grok 模型。

**岛背景（设置 → 岛背景）：** 默认就是原来的赛博毛玻璃霓虹极光，不选就不会变。想换的话，可以另选「纯色」「渐变」（6 个预设 + 自己挑色标和角度）或「图片」（从磁盘选一张，可调模糊）；随时点「默认」切回原样，自定义的颜色和图片会保留，下次还能切回来。霓虹边框和分隔线不变；毛玻璃仍在最底层。

- 「暗化」给背景盖一层暗色，保证白字和霓虹边框清楚。背景偏亮时会自动提高最低暗化（图片至少 18%），设置里会提示。
- 「不透明度」调低会透出下面的毛玻璃；「极光叠加」把流动极光轻轻叠在自定义背景上（设为 0 就完全静止）。
- 改动即时生效，设置页后面的岛本身就是预览。「全部重置」回到默认背景，并清掉自定义颜色和复制的图片。
- 选的图片会复制到 `~/Library/Application Support/GrokIsland/backgrounds/`，原图之后移动或删除都没关系；换图时旧的副本会被清掉。其余选项存在 UserDefaults（`islandBackground`）。收起时的细条保持极光。

**状态灯（PR / Cloud Agent）：** 细条和标题栏左侧的圆点。

- 有 Cloud Agent 在跑（`GET /v1/agents` 里的 `ACTIVE`）、有待合并的 PR，或者岛上有 Grok 任务在跑时，圆点会呼吸闪烁；PR 的 CI 失败时变橙色。
- 有任务开始或结束时，岛的边框闪两下。
- 点圆点可以看列表，点某一行会打开对应页面。
- PR 通过本机已登录的 `origin` CLI 读取（默认仓库 `leowang142857/GrokIsland`，可在设置里改）。内容已经全部并入 `main` 的 PR 不计入。

**展开后的分层：** 从上到下依次是 任务状态灯 → DDL 能量条 → 三个功能条 + 问 Grok → 功能模块 / 运行记录。收起时只剩一条细条：最左边是锁，接着每个任务一颗灯（超过 3 个时显示 2 颗 + 数字），右边是最急的 DDL 倒计时。带刘海的 MacBook 上细条紧贴摄像头外壳，只在刘海两侧各露出约 56 pt；没有刘海的屏幕上是约 164 pt 宽的小胶囊。

**每个任务一颗灯：** 岛上的 Grok / 本地运行、Cloud Agent、PR 各自一颗灯。排队 / 运行中会呼吸，完成是绿色、失败是红色，刚结束的任务会保留约 90 秒。展开后状态层是一排可点的小胶囊：点岛上的任务打开结果，点 Agent / PR 打开对应网页。

**DDL 能量条：** 三条功能条上面只有一条能量条。每个未完成的任务是里面的一格，不会各自再长一条。整条的颜色看格子数量：3 个及以内是绿色，4 到 6 个是橙色，7 个及以上是红色。鼠标悬停会展开列表（点击修改、圆圈标记完成、× 删除），下面可以直接输入，比如「周五 18:00 交实验报告」「明天下午3点 组会」「3小时后 开会」，会自动识别时间，也可以用日期框手动改。保存在 `Application Support/GrokIsland/deadlines.json`。

**运行记录：** 「运行记录」页里可以只看 Grok 回答；「清理已完成」一键清掉所有已完成 / 失败 / 已取消的记录；「选择」后可以多选删除，也可以用每行右侧的垃圾桶或右键菜单删单条（删除运行中的记录会先取消）。记录保存在 `Application Support/GrokIsland/run-journal.json`，重开 app 后问 Grok 的结果还在；退出时还没跑完的会标成「已中断」。主页的「上次：…」一行可以一键重新打开最近一次 Grok 回答。

**拖放反馈：** 拖着文件 / 链接经过岛时，模块区上方会提示「松手发送到「翻译」→ Grok 解答」；悬停的模块方块会放大并显示「松手发给 Grok / 松手本机执行」。松手后方块先显示「读取中…」，然后绿色「已发送 N 项」或红色「没发出去」，之后方块角上的小灯跟着这次运行变化。没放到任何模块上会提示「这次没有发送」。

**Grok 快捷按钮：** 整理错题、解答题目、检查代码，外加一个「问 Grok」输入框。

- 点按钮时，会截当前最前面的窗口（不会截到岛本身）；如果前台是 Safari、Chrome、Arc、Edge 等浏览器，还会带上当前网址，一起交给 Grok。
- 结果显示在岛上，可以拷贝，也可以跳到 Cursor 的 Cloud Agent 页面继续追问。
- 第一次使用时，macOS 会要求开启屏幕录制权限（开启后要重开 app）；读取浏览器网址时会请求自动化权限。

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

## Linux / Cloud Agent (headless core)

The SwiftUI + AppKit app only builds on macOS with Xcode, but the `GrokIslandCore`
package (module CRUD, drop intake, run state machine, executors) is
platform-agnostic and its XCTest suite runs on Linux. `Combine` is Apple-only, so
on non-Apple platforms the core transparently uses
[`OpenCombine`](https://github.com/OpenCombine/OpenCombine) for
`ObservableObject`/`@Published` (guarded by `#if canImport(Combine)`; macOS keeps
using real Combine). With a Swift 6 toolchain installed:

```bash
swift build            # builds GrokIslandCore
swift test             # runs the full core test suite
```

A Cloud Agent environment is defined under `.cursor/` (`environment.json` +
`Dockerfile`, based on the official `swift:6.0.3-noble` image) so agents can build
and test the core headlessly.

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
| `RunJournal` | Run state machine + progress / notifications, optional JSON persistence |
| `TaskLightBoard` | Per-task lights from runs + Cloud Agent / PR snapshot |
| `DeadlineStore` / `DeadlineParser` | DDL list persistence, free-text due-date parsing, energy / urgency |
| `IslandBackgroundStyle` | Expanded-island background (aurora / solid / gradient / image) and its readability veil; persisted by `IslandSettingsStorage` |
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
engine.clearFinishedRuns()                     // one-click cleanup, returns count
engine.deleteRuns(ids: selectedIDs)            // cancels active ones first
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
  RunJournal.swift            # run records (persisted in the app)
  ExecutionRouter.swift
  IslandEngine.swift
  TaskLights.swift            # one status light per run / Cloud Agent / PR
  Deadlines.swift             # DDL store, parser, energy
  IslandBackground.swift      # custom island background style, presets, readability veil
  ActivityViews.swift         # status lights, activity list
  DeadlineViews.swift         # DDL energy bar
  RecordViews.swift           # run records list (clear / multi-select delete)
  GrokViews.swift             # function strips, run detail, settings
  BackgroundViews.swift       # settings section for the island background
Tests/GrokIslandCoreTests/
```
