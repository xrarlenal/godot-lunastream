# 0013 · CPU 帧导入器与轮换纹理池

| 项 | 值 |
|---|---|
| 提交 | `feat(godot): CPU 帧导入器与轮换纹理池（0013）` |
| 日期 | 2026-09-24 |
| 阶段 | P0 |
| 依赖 | 0002/0004/0007（池容量的来源）、0010/0011（产帧的软解后端） |

## 这个功能点做了什么

软解帧第一次进了 GPU。这条链路是：

```
ffsw 解出的 CPU NV12（系统内存）
        │  core.texture_pool 决定"还给谁"
        ▼
CpuFrameImporter.import()
        │  两块 RD 纹理：亮度 + 交织色度
        ▼
ImportedSurface { y, uv, spec, slot }  →  用完 release()
```

它兑现的是 PLAN 里"软解帧的 CPU 平面导入（轮换纹理池，稳态不新建纹理）"这一行，
也是呈现层的第一站——后面 0014 的运行时分发、0018 的 `VideoStreamPlayback` 都骑在
这个接口上。

## 为什么现在做

硬解路径有系统句柄可以别名（CVPixelBuffer / D3D11 纹理 / dma-buf），软解**没有**：
帧在系统内存里，必然有一次 CPU→GPU 拷贝。既然如此，这条路上能优化的只剩两件事：
别每次新建纹理、别多做拷贝。这两件事都是纯逻辑（池的分配决策）加一层薄薄的
引擎调用，正好符合"能进 core 的先放 core，引擎侧只留薄胶水"。

## 实现要点

### 1. 池管空间，回收环管时间

`core/texture_pool.zig` 只管一件事：这一帧该写进哪块纹理。与 0004 的回收环互补——
回收环管"这块表面什么时候能还"，池管"还给谁"。容量取自 core 已有的公式
`requiredPoolDepth(队列可用 7, frame_latency 4) = 12`，并用**编译期断言**钉住
（改了池深忘了公式，或反过来，编译就红）。

三条语义各有测试：轮转取用（不固定复用同一个，免得盖掉消费者手里那块）、
已创建的槽位优先复用（稳态零分配）、取满返回 null（背压，不覆盖）。

### 2. 规格变化分两种，因为"销毁"可能是错的

宽高或位深一变，旧纹理尺寸/格式就对不上了，必须整体作废。但**能不能立刻销毁，
取决于有没有帧还在用**：

| 情形 | 处置 | 理由 |
|---|---|---|
| 空闲时换规格 | 立刻销毁旧纹理 | 没人引用，留着只是占显存 |
| 有帧在用 | 留成孤儿，等句柄销毁时释放 | 消费者手上可能就是它，销毁等于悬垂引用 |

孤儿路径是罕见路径（流中途换分辨率/位深），所以用定长表并计数；表满时宁可留着
不释放也不冒险，并打一条告警留痕。

### 3. 两块纹理的尺寸算术

| 平面 | 8-bit | 10-bit | 纹理宽高 |
|---|---|---|---|
| 亮度 | `width` 字节/行 | `width*2` | `width × height` |
| 色度 | `width` 字节/行 | `width*2` | `width/2 × height/2` |

这样每张纹理的行宽**恰好等于平面一行字节数**，上传就是整块搬运。行距大于行宽时
（契约允许，当前 shim 不用）退化成逐行紧凑化，代码里留着这条分支而不是断言"不会
发生"——那是契约允许的输入。

## 这个功能点的"测试"是什么

呈现层的东西 core 单测够不着（要真的 RD），gdzig 自带的引擎内测试桥又是
`--headless` 的（没有 RenderingDevice）。所以走的是 0003 的老路：

```bash
zig build godot-importer-selftest      # 需要带渲染上下文的 Godot（会短暂开窗）
```

`example/gdextension-smoke/importer_smoke.tscn` → GDScript 驱动 → 扩展侧的
`LunaSelfTest` 跑 24 项检查。**回读比对是其中最硬的一条**：上传什么字节，回读就是
什么字节（8-bit 亮度/色度、10-bit 亮度各一组），它同时证明布局正确、上传确实执行、
没有偷偷做格式转换。

池语义那几条（并发开新槽、归还后复用不新建、取满报背压、空闲换规格立刻释放、
忙时换规格留孤儿）全部在真引擎里跑一遍，而不是只在 core 单测里跑。

## 验证方式与结果

```bash
zig build test                        # 124/124（core 118 + shim ABI 6）
zig build godot-importer-selftest     # 24 项检查，0 失败，RESULT=PASS
zig build ffsw-selftest               # 31 项（未受影响）
zig build decode-smoke                # SMOKE=PASS（未受影响）
Godot --headless --path example/...   # 0003 的 headless 自检仍 RESULT=PASS
```

### 过程中的四个坑（都写进了代码注释）

1. **`PackedByteArray.ptr()` 不是数据指针**。gdzig 里它是不透明包装（`_: [16]u8`
   放 CowData 句柄），`ptr()` 返回的是包装自己的地址。第一版拿它当缓冲区写，往
   16 字节里写几万字节 → **SIGSEGV**。GDExtension 的 C API 也没有"取整块数据指针"
   的入口，只有逐下标的 `packed_byte_array_operator_index`；靠"Godot 的
   PackedByteArray 底层连续"这一实现事实取 `index(0)` 再按长度读写，并在
   `writeBase` / `equalBytes` 两处单点封装写明。
2. **`textureGetData` 要求纹理带 `CAN_COPY_FROM` 用途位**（引擎文档原话），否则只
   返回空数组（实测 size = 0）；`CPU_READ` 让读回更快但与正确性无关。两者都挂在
   `Options.cpu_readback` 下，生产路径默认关——对生产它们只是白白的带宽/内存代价。
3. **Godot 类名来自文件名**。gdzig 取 `@typeName(@This())` 的短名再按 casez 的 type
   规则转换，而文件根类型名就是文件名。文件叫 `self_test.zig` 时注册出来是
   `SelfTest`（实测：候选类名里就它一个不带 Luna 前缀），改名 `luna_self_test.zig`
   才是 `LunaSelfTest`。
4. **主线程拿到的是非本地 RenderingDevice**。`submit()`/`sync()` 在它上面会被拒
   （"Only local devices can submit and sync."，实测），而 `textureUpdate` 的结果
   跨帧也读不回来（仍是全零）。所以自检改用**本地设备**（`createLocalRenderingDevice`）
   来验证导入器逻辑。

## 已知限制 / 下一步

- **第 4 条带来的缺口**：本地设备的用例证明导入器的**逻辑**（布局算术、槽位轮转、
  上传调用、字节一致性）正确，但**没有**证明主设备的可见性。主设备上的正确性要到
  呈现管线那一步用"真的出画"来验（0014/0018）。这是本步最大的未验证面，写在这里
  而不是留给读者猜。
- `LunaSelfTest` 是**测试用探针类**，不承诺 API 兼容；它随扩展一起编译进去，因为
  自检要在 ReleaseSafe 的示例构建里跑。发布前若要收窄 API 面，可以按构建模式条件
  注册（尚未做）。
- 孤儿表满时的行为是"留着不释放 + 告警"，不是"立刻安全释放"——安全释放需要逐代
  跟踪引用，属于真实使用中出现再做（当前每条流换规格的次数极少）。
- 退出时那条 `ObjectDB instances leaked at exit` 仍在（0022 的残余），本步没有碰它。
- 下一步（0014）：导入器运行时分发——CPU 与平台（Metal/D3D12/Vulkan）两条导入路径
  用同一个接口，按平台与后端选择其一。
