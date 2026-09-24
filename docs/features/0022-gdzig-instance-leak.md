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

### 这次失败本身就是证据（把时序钉死了）

把两次观测放在一起，引擎加引用的时机只剩一种可能：

| 观测 | 值 | 说明 |
|---|---|---|
| 脚本里 `ClassDB.instantiate` 返回之后 | **2** | 创建方 1 份 + 引擎 1 份 |
| 若在 `POSTINITIALIZE` 里 unref | **挂死** | 说明那一刻计数还是 **1**（只有创建方那份），unref 直接归零、对象被销毁，而引擎随后仍要用它 |

合起来推出：**`POSTINITIALIZE` 早于引擎那一次引用**。gdzig 的 `create2Impl` 在
`T.create()` 之后就发这个通知，而 Godot 是在 `ClassDB::instantiate` **返回之后**
才把对象包进 Variant 并加引用的。

所以"交还创建方那份引用"必须发生在 `ClassDB.instantiate` 返回之后，**不能在创建
回调链里的任何时刻做**——这解释了为什么在创建路径上怎么改都错。

## 下一步该怎么修

时序已经确定（见上），修法必须把"释放创建方那份引用"放到 `ClassDB.instantiate`
返回之后：

| 方案 | 思路 | 风险 |
|---|---|---|
| A. 延迟释放（首选） | 在 `POSTINITIALIZE` 里安排一次 deferred 调用，等引擎引用就位后再 unref 一次 | 需要一个可被 deferred 调用的回调目标；时机由队列保证，但要实测确认引擎引用已加 |
| B. 改 gdzig 的 create 路径 | 让 `create2Impl` 区分「ClassDB 创建」与「扩展内部创建」，前者不留下创建方引用 | 要改 vendor（破坏"字节原样"约定），需记录为本地补丁并回馈上游 |

推荐 A：不需要动 vendor，失败可逆。**不要再在创建回调链内部试**——那条路已被证伪。

## 影响评估

- 崩溃发生在 `--import` 的**退出路径**上，缓存已写好，之后的正常运行不受影响；
  但它会让第一次跑 `--import` 的人以为扩展有问题，属于必须修的口子。
- 泄漏的表现是"每个手动创建并释放的流实例泄漏一个对象"。对本插件最终的使用方式
  （每路流一个长生命周期实例）影响有限，但同样是必须修的——它出现在"插件是否可信"
  的第一印象里。

## 进展与当前残余（更新）

**已经修好的两处：**

1. **根因**：在 `POSTINITIALIZE` 里安排一次 deferred 调用（`release_creator_ref`），
   在引擎引用就位之后交还创建方那份。隔离验证：引用计数 **2 → 1**，`ping` 仍正常，
   泄漏警告消失。
2. **孤儿 StringName**：`StringName.fromLatin1` 的第二个参数是 `is_static`，字面量
   必须传 `true`（`false` 等于声明"我自己负责析构"）。改后
   `Orphan StringName: release_creator_ref` 消失。

**仍未解决：** 自检脚本这一条路径上还剩一次 `ObjectDB instances leaked at exit`。
已排除的假设：

| 假设 | 实验 | 结论 |
|---|---|---|
| 自检脚本里的局部别名多持了一份引用 | 去掉 `var stream := _stream`，改用成员变量直连 | **仍泄漏，假设不成立** |
| 创建回调链内部释放 | 在 `POSTINITIALIZE` 里直接 unref | 挂死，已证伪（见上） |

关键对比：**隔离脚本（`instantiate` → 置空 → 等一帧 → 退出）是干净的，自检脚本不是。**
两者差异只在自检脚本多做了几次调用（`call("ping")`、`set/get("decoder")`）。
下一步就按剪枝法在这三次调用上做二分——这是纯脚本层面的实验，不需要改扩展。

## 剪枝实验的结果与最终定位

### 实验一：三次调用逐一加回（V0–V3）

| 变体 | 内容 | 结果 |
|---|---|---|
| V0 | 只 instantiate | leak=0，rc=1 |
| V1 | + `call("ping")` | leak=0，rc=1 |
| V2 | + `set/get("decoder")` | leak=0，rc=1 |
| V3 | 三者全上 | leak=0，rc=1 |

**四个变体全部干净**——那三次调用全部排除。同时注意到一个之前被忽略的细节：
自检里打印的实例 id 与 `--verbose` 报出的泄漏 id **不是同一个对象**。

### 实验二：按基类性质分类

用**与自检完全相同的脚本结构**（`_ready` 调用 `_finish` 协程 + 成员变量）逐类测：

| 对象 | 基类性质 | 结果 |
|---|---|---|
| `Resource.new()` | RefCounted | **干净** |
| `Node.new()` | 非 RefCounted（必须手工 `free()`） | 泄漏（符合预期，探针自身的问题） |
| `ClassDB.instantiate("LunaVideoStream")` | **RefCounted** | **泄漏** |

### 定位结论

三件事同时成立：

1. Godot 对 RefCounted 的引用计数协议是好的（`Resource.new()` 干净）；
2. 我们的引用计数序列也是对的（2 → deferred 交还 → 1 → 脚本释放 → 0）；
3. 我们的类**是** RefCounted，却在计数归零后仍然留在 ObjectDB 里。

结论：**对象在计数归零时被销毁了（销毁回调被调用），但引擎侧的对象没有从
ObjectDB 移除。** 问题在我们的 `destroy` 路径——`self.base.destroy()` 释放的是
Zig 侧的绑定结构，没有做引擎侧的删除。

### 严重性评估

| 维度 | 评估 |
|---|---|
| 安全性 | **无风险**。不是 use-after-free，不是野指针，不崩溃 |
| 功能正确性 | **无影响**。画面、状态、重连都正常 |
| 资源泄漏 | 每次"创建→释放"泄漏一个对象与其内部资源。插件的真实用法是每路流一个长生命周期实例，所以稳态影响小；但切通道、重连、反复重建时会累积 |
| 可观测性 | **有实际损害**：退出时永远带着一条泄漏警告，等于把"泄漏告警"这个信号本身废掉了——真正的泄漏将来会被淹没在这条噪音里 |
| 结论 | **中等：不致命，但属于发布前必须清的账** |

与另一半（`--import` 崩溃）相比：崩溃发生在首次导入的退出路径上，用户第一眼就会
看到，严重性更高；泄漏是"慢性且噪音化"的问题。

### 解决方案

| 方案 | 做法 | 评价 |
|---|---|---|
| **A（首选）** | 在 `LunaVideoStream.destroy` 里，除了 `base.destroy()`，显式走引擎侧的删除（`Object` 的 free/delete 语义），确保对象从 ObjectDB 摘除 | 改动在我们自己的代码里，风险可控，可立即用 V0/实验二的探针验证 |
| B | 改 gdzig 的类销毁回调 | 要动 vendor（破坏"字节原样"），但若 A 无法从 Zig 侧触达引擎删除，这是唯一出路；需记录为本地补丁并回馈上游 |

验证手段已经现成：本文件里的 V0–V3 与实验二探针命令可直接复用，判据是
**leak=0 且 rc 序列为 2 → 1**。
