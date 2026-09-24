# 0015 · Metal 呈现导入器（macOS 零拷贝）

| 项 | 值 |
|---|---|
| 提交 | `feat(godot): Metal 呈现导入器（0015）` |
| 日期 | 2026-09-24 |
| 阶段 | P0 |
| 依赖 | 0014（导入接口与分发）、0010/0011（帧的形状） |

## 这个功能点做了什么

macOS 上的零拷贝路径通了，整条链路是：

```
CVPixelBuffer（IOSurface 支撑，硬解帧的原生形状）
        │  CVMetalTextureCache（不复制一个字节）
        ▼
两块 MTLTexture 视图（平面 0 = 亮度 R8，平面 1 = 交织 CbCr RG8）
        │  RenderingDevice.texture_create_from_extension
        ▼
Godot 的纹理 RID  →  交给分发器（0014）与呈现管线
```

这是本插件相对"CPU 上传路径"的核心差异：**这条路上没有 CPU 读回**。

## 为什么现在做

0014 把接口立住了，macOS 又是三平台里唯一能在这台机器上验证的，所以先做它——先让
"零拷贝这条路到底走不走得通"这个问题有答案，而不是等三平台代码都写完再一起赌。

## 实现要点

### 1. 造一块"硬解形状"的输入来验证

本仓库还没有硬解后端（`ffvt` 未落地），而 Metal 导入器吃的正是硬解帧的形状
（`native_surface` 加 `CVPixelBuffer`）。所以自检自己造一块：`nv_cv_probe_create()`
用 `CVPixelBufferCreate` 造一块 **IOSurface 支撑**的 NV12 缓冲。

关键在于"IOSurface 支撑"：普通内存的像素缓冲根本无法被 Metal 别名，造出来的也就
不是真路径的输入。所以 `kCVPixelBufferIOSurfacePropertiesKey` 与
`kCVPixelBufferMetalCompatibilityKey` 都是必需的，创建失败直接返回 NULL——宁可报错，
也不给一个"验证了另一条路"的假绿灯。

### 2. 所有权：零拷贝意味着"帧不能提前还"

两条路径的释放责任**刻意不同**，这一点写在接口的文档注释里：

| 路径 | 帧什么时候能还 | 为什么 |
|---|---|---|
| CPU 上传 | 上传完就能还 | 字节已经拷进纹理了 |
| 平台零拷贝 | 纹理不再被 GPU 用之后 | 纹理**就是**那块 IOSurface |

所以平台导入器在这一步**接管**帧的释放：消费者只调 `Surface.release()`，导入器在
释放纹理视图的同时调用帧自带的 `release_hook`。两处各还一半，不会双重释放，也不会
提前释放。

### 3. 在飞帧用定长表

与 CPU 路径同理（0004 回收环 + 队列深度），12 槽；取满返回 `PoolExhausted`（背压），
不覆盖。重复释放是空操作。

## 自检覆盖了什么

Metal 部分 9 项（总计 41 项），最硬的两条是**像素级证据**：

| 检查 | 锁定的行为 |
|---|---|
| 造出 IOSurface 支撑的 NV12 像素缓冲 | 输入是真路径的输入 |
| 两个平面都可写（缓冲已锁定） | 测试内容真的写进去了 |
| 原生帧被分给 Metal 导入器 | 0014 的平台路由确实把帧送了过来 |
| 走平台路径时没有动 CPU 计数 | 没有偷偷走 CPU 路径 |
| Metal 路径交出亮度 + 交织色度两块纹理 | `PlaneSet` 的实际形态 |
| 导入器记账：在飞 1 帧、创建 2 块纹理 | 生命周期记账 |
| 把别名纹理拷进暂存纹理 | 见下面第 1 个坑 |
| **Metal 零拷贝：亮度平面逐字节一致** | 按像素缓冲自己的行距写入、按纹理的紧凑行距读回，逐字节相同 |
| **Metal 零拷贝：色度平面逐字节一致** | 同上（色度平面） |

像素级那两条是这一步的价值所在：它同时证明了别名把行映射对了、平面选对了
（平面 0 亮度、平面 1 色度）、RG8 的交织顺序对了。

## 验证方式与结果

```bash
zig build godot-importer-selftest     # 41 项检查，0 失败，RESULT=PASS
zig build test                        # 124/124（未受影响）
zig build ffsw-selftest               # 31 项（未受影响）
zig build decode-smoke                # SMOKE=PASS（未受影响）
Godot --headless --path example/...   # 0003 的 headless 自检仍 RESULT=PASS
```

机器：Apple M1 Pro / Metal 4.0 / Godot 4.6.2。

### 过程中的两个坑（都写进注释）

1. **Godot 的 Metal 驱动拒绝读回别名进来的纹理**。直接 `textureGetData` 会打印
   driver 报错（`drivers/metal/rendering_device_driver_metal.mm:585`）并返回空数组
   ——第一版就是这样"读回全零"。绕法是先用 `texture_copy` 在 GPU 内部拷到一块
   Godot 自己创建的暂存纹理（带 CAN_COPY_TO、CAN_COPY_FROM、CPU_READ），再读暂存
   纹理。这条路本身也是未来呈现管线要走的路：真正出画时也是先算再读，而不是直接读
   别名纹理。
2. **Zig 的构建能直接编译 `.m` 并链框架**（Metal / CoreVideo / CoreGraphics /
   Foundation），但 `.m` 里没有 ARC 时要自己 `CFRelease`——`CVMetalTextureRef` 与
   cache 都在 `nv_cv_metal_view_destroy` 里还，漏一处就是每帧泄漏两张纹理视图。

## 已知限制 / 下一步

- **没有硬解后端**：这条路的输入目前只能由自检造。真实帧要等 `ffvt`（VideoToolbox）
  落地——它不在推进表的 0000–0023 里，属于 PLAN 里"能力基线"的一部分（源工程已有）。
  在它落地之前，真实使用中不会出现 `native_surface` 帧。
- 只验证了 8-bit NV12（`420YpCbCr8BiPlanarVideoRange`）。macOS 的 10-bit 硬解格式是
  `x420`（CoreVideo 的 10 位半平面、**左对齐**），它的对齐换算属于色彩层与呈现管线
  那一步，本步没有碰。
- 暂存纹理的 `texture_copy` 只用于自检；正式呈现要走 compute pass（色彩转换，再加
  输出到稳定的 Texture2DRD）。
- 下一步（0016）：Windows D3D12 呈现导入器——**需要 Windows 真机**，见推进表里
  标出的卡点。
