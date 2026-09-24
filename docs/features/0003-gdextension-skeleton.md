# 0003 · GDExtension 最小可加载骨架

| 项 | 值 |
|---|---|
| 提交 | `feat(godot): GDExtension 最小可加载骨架` |
| 日期 | 2026-09-24 |
| 阶段 | P0 |
| 依赖 | 0000 |

## 这个功能点做了什么

仓库现在能产出**真正的 Godot 扩展**：`zig build` 生成 `liblunastream.dylib` 并
安装进示例工程的 `addons/lunastream/`；Godot 4.6.2 能加载它，GDScript 能实例化
`LunaVideoStream`，枚举属性和方法的绑定都可用。

一句话：**"这个仓库能不能变成一个 Godot 插件"这个问题，从这一步起不再是假设。**

## 为什么现在做（原计划在 0018）

推进表原本把它排在 core 全部写完之后。提前做的理由是风险分布：

这个项目真正的未知不在纯逻辑（那些有单测兜着），而在工具链——gdzig 能不能对
Godot 4.6.2 生成绑定、`.gdextension` 能不能被引擎加载、GDScript 能不能
`new` 出我们的类。这几件事只有真的跑一遍才知道。如果拖到第 18 步才发现绑定层面
有问题，前面 17 个功能点都得停下来等。

代价是编号顺延：本点占 0003，其后全部 +1。0001 / 0002 文档里引用旧编号的地方
已在同一次提交里改掉。

## 实现要点

### 1. gdzig 按字节 vendor

`vendor/gdzig/` 是从快照压缩包原样拷进来的（136 文件 / 988 KB），记录见
`vendor/README.md`。之所以不用子模块：这个分支是 fork 分支而非上游 release，
子模块会让别人 clone 到"该分支上更新但未经验证"的提交，构建就不可复现了。

### 2. 继承 `VideoStream`，不自造节点

`LunaVideoStream extends VideoStream`，于是 `VideoStreamPlayer` 的行为全部白拿，
用户也不必为一路视频多挂一层节点。依据是 Godot 官方文档里 `VideoStream.file` 的
说明原文："The video file path **or URI** that this VideoStream resource handles"。

### 3. 两个构建目标分开（本仓库最重要的结构决定）

| 命令 | 需要 Godot | 内容 |
|---|---|---|
| `zig build test` | **否** | 只跑 core 单测，任何机器都能跑 |
| `zig build` | 是 | 生成绑定、构建扩展、装进示例工程 |

这让"逻辑对不对"和"绑定能不能用"成为两件可以分别定位的事。core 那 27 个测试
至今不依赖引擎。

### 4. Zig 0.16 的硬规则：字段必须连续

第一次编译报 `declarations are not allowed between container fields`：类结构里
不允许"字段 → 函数 → 字段"。所有字段必须集中放在最前，函数一律写在后面。
这一点已写进 `luna_video_stream.zig` 的注释，避免下次踩。

### 5. 三处工具链细节

- **bindgen 会 spawn `zig fmt`**：它要求 `zig` 在 `PATH` 上，只给绝对路径调用
  是不够的（会报 `FileNotFound`）。构建命令因此必须把工具链目录加进 `PATH`。
- **gdzig 自身的 git 依赖需要缓存**：它的 `.godot` 依赖指向
  `git+https://github.com/claytercek/godot-versions`，本机对 github.com 的 git
  访问不通（`ls-remote` 超时）。用离线快照补进 Zig 全局缓存后解决。
- **浮点精度**：`-Dprecision` 必须与目标 Godot 一致（gdzig 在编译期定死
  `Variant`/`real_t` 布局），默认 `float` 对官方构建正确。

## 这个功能点的"测试"是什么

本点没有 Zig 单元测试——它的可验证对象是**引擎的加载行为**，Zig 单测表达不了。
替代品是示例工程里的自检脚本 `example/gdextension-smoke/smoke.gd`：
它逐项检查并以退出码报告，性质与单测相同（可重复、可进 CI、有明确 PASS/FAIL）。

| 检查项 | 锁定的行为 |
|---|---|
| 扩展已加载且类已注册 | `.gdextension` 被扫描到、入口符号被调用、类注册成功 |
| 类可实例化 | `ClassDB.instantiate("LunaVideoStream")` 能拿到对象 |
| 继承了 `VideoStream` | 确实是 `VideoStream` 子类（而不是被退化成 `Object`） |
| 方法绑定可用 | `ping()` 返回 `lunastream/<版本>`，版本号来自 core 模块——同时证明扩展与 core 的模块接线是通的 |
| 枚举属性写入与回读 | `decoder` 属性的 setter/getter 与枚举提示生效 |
| 越界枚举值被忽略 | 传 99 时保持上一个合法值 |

## 验证方式与结果

```bash
zig build test                                    # 27/27 通过（core，未受影响）
zig build -Dgodot-path=/Applications/Godot.app/Contents/MacOS/Godot
"/Applications/Godot.app/Contents/MacOS/Godot" --headless --path example/gdextension-smoke --import
"/Applications/Godot.app/Contents/MacOS/Godot" --headless --path example/gdextension-smoke
```

结果：

- 扩展构建成功，产物 `liblunastream.dylib` 238 KB；
- 自检 **6/6 PASS**，`RESULT=PASS`，退出码 0；
- `ping()` 返回 `lunastream/0.0.0`。

## 已知问题（都带对照证据，非本步引入）

调查过程中发现两个现象，都用"源工程的扩展做同样操作"做了对照，结论是**两者
共有**，与本次实现无关：

| 现象 | 触发条件 | 对照结果 |
|---|---|---|
| 退出时崩溃（`EditorHelp::_class_desc_select` → `DocTools::generate`） | 干净状态下 `--headless --import`，在**退出路径** | 源工程的 `libnative_video.dylib` 在同样的干净状态下崩溃位置完全一致 |
| `ObjectDB instances leaked at exit` | GDScript 实例化我们的类之后退出 | 源工程实例化 `NativeVideoStream` 时同样泄漏 |

已记入推进表候选条目（0022）。当前影响可控：崩溃发生在导入**退出时**，缓存已经
写好，随后的正常运行不受影响；泄漏是进程退出前的一次性报告。

## 已知限制 / 下一步

- `_instantiate_playback()` 目前返回 null——播放实现属于 VideoStream 集成那一步。
- 只在 macOS + Godot 4.6.2 上验证过；Windows / Linux 的库名已在清单里占位，
  但未构建过。
- 下一步（0004）：帧回收环，回到 core 层继续把可被单测覆盖的部分做完。
