# 0022 · gdzig 类实例泄漏与 headless 导入崩溃（调查记录）

| 项 | 值 |
|---|---|
| 提交 | `docs: 记录 0022 的调查结论（未修复）` |
| 日期 | 2026-09-24 |
| 阶段 | 待评估 |
| 状态 | **已定位，未修复** |

## 两个现象

| 现象 | 触发条件 |
|---|---|
| `ObjectDB instances leaked at exit` | GDScript 实例化我们的类之后退出 |
| 退出时崩溃（`EditorHelp::_class_desc_select` ← `DocTools::generate`） | 干净状态下 `--headless --import`，发生在**退出路径** |

## 隔离实验（四次，都可复现）

| 实验 | 做法 | 结果 |
|---|---|---|
| 1 | 把一个**不注册任何成员**的裸类（无方法、无属性、无虚函数）编进扩展 | `--import` **照样崩** |
| 2 | 裸类 + 极简脚本（只 instantiate 再 quit） | **照样泄漏** |
| 3 | 对照组：源工程的 `libnative_video.dylib`，同样操作 | **崩溃位置一致、同样泄漏** |
| 4 | 打印引用计数 | 我们的类 **refcount = 2**，而 `Resource.new()` = 1 |

实验 1–3 的结论：**与我们的成员注册无关**，是 gdzig 类注册/实例化机制的共有行为
（源工程的扩展同样中招，只是流的生命周期是整个进程，所以从没被发现）。

实验 4 把范围收窄到一件具体的事：**实例化后多出一份引用**。

## 根因指向

gdzig 的 `src/builtin/variant.zig` 里有一段注释写明了它的约定：

> For RefCounted objects, manually construct the Variant and call `reference()` to
> share ownership. We bypass `variantFromType` because it uses `init_ref()` which
> only works correctly for first-time ownership transfer.

也就是说 gdzig 假定**创建方持有一份引用**。但走 Godot 的 `ClassDB.instantiate`
创建扩展类时，引擎自己也会加一份引用，于是引用计数停在 2：脚本那份释放之后还剩 1，
对象永不销毁。多出来的那份就是泄漏。

这是一条**RefCounted 基类专属**的路径：gdzig 自带的例子用 `Control`（非 RefCounted）
做基类，正好绕开了它，所以上游没暴露这个问题。

## 试过的修法（失败，已回退）

在 `NOTIFICATION_POSTINITIALIZE` 里交还创建方那份引用：

```zig
pub fn _notification(self: *LunaVideoStream, what: i32, reversed: bool) void {
    _ = reversed;
    if (what == Object.NOTIFICATION_POSTINITIALIZE) {
        _ = RefCounted.upcast(self.base).unreference();
    }
}
```

**结果：Godot 挂死**（进程不退出，需手工 kill）。说明在 `POSTINITIALIZE` 这个时刻
引擎的引用**还没有**就位——此时 unreference 让计数归零，对象被销毁，而引擎随后仍要
使用它。这条路径不通，已回退，工作区保持干净。

## 下一步该怎么修（候选，按风险排序）

| 方案 | 思路 | 风险 |
|---|---|---|
| A. 把创建方的引用在**一帧后**释放 | 用 `call_deferred` 式的延迟释放，确保引擎引用就位 | 需要一处延后机制；时机仍需实测确认 |
| B. 改 gdzig 的 create 路径 | 在 `create2Impl` 里对 RefCounted 基类做引用交接 | 要改 vendor（破坏"字节原样"约定），需记录为本地补丁 |
| C. 查 Godot 侧 `ClassDB.instantiate` 对扩展类的引用语义 | 确认引擎到底加了几份、何时加 | 需要读 Godot 源码，最慢但最根本 |

推荐先做 C 再动 A/B：现在对"引擎何时加那份引用"只有推断，没有证据；A 之所以挂死
正是推断错了。把时序确认清楚，修法通常只有一行。

## 影响评估

- 崩溃发生在 `--import` 的**退出路径**上，缓存已写好，之后的正常运行不受影响；
  但它会让第一次跑 `--import` 的人以为扩展有问题，属于必须修的口子。
- 泄漏的表现是"每个手动创建并释放的流实例泄漏一个对象"。对本插件最终的使用方式
  （每路流一个长生命周期实例）影响有限，但同样是必须修的——它出现在"插件是否可信"
  的第一印象里。
