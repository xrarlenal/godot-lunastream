# vendor/ 说明

## gdzig

把 Zig 与 Godot 的 GDExtension 接口对接起来的绑定生成器。**本仓库 vendor 的是
压缩包原样内容，不做任何本地修改**——这样升级时可以整目录替换，并且能用压缩包
校验。

| 项 | 值 |
|---|---|
| 上游 | `https://github.com/gdzig/gdzig` |
| 本仓库用的分支 | `media-streams-fixes-0.16`（gdzig 的 0.16 适配分支） |
| 快照提交 | `d945d1f5f3bcc0f65b71e9e4338f73fc9486ba2e` |
| 来源压缩包 | `gdzig-0.16.zip`（2026-09-05 下载） |
| 许可证 | MIT（见 `gdzig/LICENSE`） |
| 文件数 | 136（其中 9 个是 gdzig 自带的编辑器/示例缓存，被本仓库 `.gitignore` 排除，不入库：`.zed/`、`example/project/.godot/`、`*.uid`） |

### 为什么 vendor 而不是用子模块

这个分支是 gdzig 的一个 fork 分支，**不是上游 release**。用子模块的话，别人
clone 到的可能是该分支上更新（且未经验证）的提交，构建结果就不可复现了。
vendor 一份快照可以保证"任何人拉到这个提交都能构建出同样的东西"。

### 升级方式

整体替换 `vendor/gdzig/` 的内容，然后更新上表的提交号，并在功能文档里记一条。
gdzig 自身的依赖（`bbcodez` / `casez` / `oopz` / `temp` / `godot-versions`）由
Zig 包管理器按 `vendor/gdzig/build.zig.zon` 里 pinned 的 url + hash 拉取，
首次构建需要联网，之后走全局缓存。
