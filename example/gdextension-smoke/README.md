# 示例工程：扩展自检

最小验证工程：确认 GDExtension 被加载、类能实例化、属性与方法的绑定可用。

## 跑法

```bash
# 1. 构建扩展并安装到本工程的 addons/lunastream/（需要 Godot 可执行文件）
#    注意：zig 必须在 PATH 上——gdzig 的 bindgen 会 spawn `zig fmt`。
zig build -Dgodot-path="/Applications/Godot.app/Contents/MacOS/Godot"

# 2. 首次运行前先导入一次，让引擎扫描到 .gdextension
"/Applications/Godot.app/Contents/MacOS/Godot" --headless --path . --import

# 3. 跑自检（退出码 0 = 全过）
"/Applications/Godot.app/Contents/MacOS/Godot" --headless --path .
```

第 2 步在 Godot 4.6.2 上会有一条**退出时**的崩溃输出（`DocTools::generate`）。
缓存在崩溃前已经写好，不影响第 3 步；原因与对照证据见
`docs/features/0003-gdextension-skeleton.md` 的"已知问题"。

## 产物放在哪

构建产物装在 `addons/lunastream/` 下，与 `lunastream.gdextension` 同目录——
清单里的库路径是相对清单自己的，两者必须在一起。产物本身不入库（`.gitignore`
已忽略动态库）。
