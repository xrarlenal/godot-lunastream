# 0014 · 导入器运行时分发（平台 / CPU 二选一）

| 项 | 值 |
|---|---|
| 提交 | `feat(godot): 导入器运行时分发（0014）` |
| 日期 | 2026-09-24 |
| 阶段 | P0 |
| 依赖 | 0013（CPU 导入器）、0009（"绝不静默降级"的同一条原则） |

## 这个功能点做了什么

呈现层从此只有**一张**导入接口：`surface_importer.zig` 定下"解码帧 → 可采样的 GPU
纹理"这条 vtable，`dispatching_surface_importer.zig` 按帧的形状选实现。

| 帧的 `surface_kind` | 谁来导 | 拷贝次数 |
|---|---|---|
| `cpu_nv12`（软解） | CPU 上传导入器 | 1 次 CPU→GPU |
| `native_surface`（硬解） | 平台导入器（Metal / D3D12 / Vulkan） | 0（句柄别名） |

0015–0017 只要实现这张表，呈现管线不用改一行。

## 为什么现在做

0013 把 CPU 路径做完了，但它当时是一个**具体类型**：调用方要认识
`CpuFrameImporter`。等 0015 的 Metal 导入器进来，如果那时才抽接口，就要同时改
0013 的调用点、0018 的接线与自检——三处一起动，出错难定位。

现在抽的代价只有一次小重构（把 `ImportedSurface` 换成与实现无关的 `Surface`，
归还改用 0004 的 `VoidClosure`），换来的是后面三步各自独立落地。

## 实现要点

### 1. 接口形状与解码后端同构

`SurfaceImporter` 和 `core/backend.zig` 的 `Backend` 一样是 ptr + vtable。这不是
为了"风格一致"，而是因为读代码的人已经学过一遍：这两处都是"运行期选实现、
调用点不该知道背后是谁"。

### 2. 两种纹理摆法写在类型里，而不是靠约定

```zig
pub const PlaneSet = union(enum) {
    interleaved_single: Rid,                          // 平台路径常见：一块纹理带色度
    luma_chroma: struct { luma: Rid, chroma: Rid },    // CPU 路径：两张
};
```

放在 union 而不是注释里，是为了让"平台路径只有一块纹理"这件事在编译期就成立，
不至于出现"某个导入器返回了两块、某个返回一块，调用方靠 if 猜"的形态。

### 3. 归还用 core 的 `VoidClosure`

两条路径要还的东西完全不同（CPU 要还纹理池的槽位，平台要告诉解码池"原生表面用完
了"），但形状一样：无参、无返回、调用一次。0004 的 `VoidClosure` 正好是这个形状，
而且它本来就带着"帧用完以后调用"的语义（`VideoFrame.release_hook` 就是它）。

CPU 侧的归还凭据是**每槽位一张票**（`Ticket { owner, slot }`）：

```zig
const ticket = &self.tickets[lease.index];
ticket.* = .{ .owner = self, .slot = lease.index };
release_hook = .{ .ctx = ticket, .func = releaseTicket };
```

这样取帧与归还都**零分配**（与 0013 "稳定态不新建纹理"的目标一致），也避免把
`self` 硬塞进闭包（`VoidClosure` 只留了上下文指针与函数指针）。

### 4. 缺平台导入器时明确拒绝，不退回去

```zig
.native_surface => {
    const platform = self.platform orelse {
        self.rejected += 1;
        return Error.UnsupportedFrame;   // 明确失败
    };
    ...
}
```

平台帧**没有** CPU 平面可上传，"退回 CPU 路径"在技术上不存在；而在语义上，
"看起来是硬解、实际走了软解"正是 0009 明令避免的假象。所以这里的选择只有一个：
明确失败，由调用方去换档位（`decoder = software`）——那是用户能看见、能决定的动作。

### 5. 分发记数

`cpu` / `platform` / `rejected` 三个计数是给 0019 的 `get_stats()` 用的。多路弱网
场景下用户最想问的就是"这一路到底走的哪条路径"，答案必须来自**实际发生的分发**，
而不是配置意图。

## 自检覆盖了什么

在 0013 的 24 项之上加了 8 项（`LunaSelfTest`，同一条 `zig build
godot-importer-selftest`）：

| 检查 | 锁定的行为 |
|---|---|
| CPU 帧被分给 CPU 上传路径 | 分派正确（cpu 计数 1） |
| 此时平台计数与拒绝计数都还是 0 | 没有误计 |
| CPU 路径交出的是「亮度 + 交织色度」两块纹理 | `PlaneSet` 的实际形态 |
| 分发结果带着帧自己的规格（64x48） | 规格随帧传递，不是从别处猜的 |
| 平台帧在缺平台导入器时被明确拒绝 | **不静默回退** |
| 拒绝被如实计数 | 可观测 |
| 拒绝平台帧时 cpu 计数仍为 1 | 拒绝路径没有偷偷导一次 |
| 分发路径交出的纹理同样逐字节可回读 | 分发之后仍走同一条上传路径 |

## 验证方式与结果

```bash
zig build godot-importer-selftest     # 32 项检查，0 失败，RESULT=PASS
zig build test                        # 124/124（未受影响）
zig build ffsw-selftest               # 31 项（未受影响）
zig build decode-smoke                # SMOKE=PASS（未受影响）
```

## 已知限制 / 下一步

- **平台导入器还不存在**（0015–0017），所以 `native_surface` 这条路目前只会返回
  `UnsupportedFrame`——这是刻意的形态：接口先立住，实现逐步填。
- 接口本身没有做"平台导入器返回的纹理格式与着色器期望是否一致"的校验；那属于
  呈现管线（着色器）那一步的事，现在校验等于凭空发明约束。
- 0013 里那条未验证面仍然在：主设备（非本地）上的可见性要等"真的出画"才算证明。
- 下一步（0015）：Metal 呈现导入器——macOS 上把 `CVPixelBuffer` 通过
  `texture_create_from_extension` 零拷贝别名成 Godot 的纹理。
