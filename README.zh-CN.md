# reaper-harness

在 Windows 上用 REAPER 无人值守地测试 VST3 插件：渲染对拍（null test）、旁路、存盘重开、反复加减实例。
每次运行都用一份私有的、隔离的 REAPER 配置，不会碰你自己的 REAPER 设置。

> **状态：** 开发中。还没有发布任何版本，命令行参数和配置文件格式都可能变。

[English](README.md)

- **每个插件项目一份配置文件。** 项目在里面列出自己的插件、轨道布局和测试场景；工具据此生成 REAPER 工程，
  经 Lua 脚本驱动 REAPER 渲染，再逐个样本比较渲染结果。
- **默认安全。** REAPER 走 Dummy 音频设备，用私有配置目录。这个目录有可能是 REAPER 的默认资源目录时，
  工具拒绝启动；只结束自己启动的进程；每轮前后都核对默认资源目录没有被改动。
- **测的就是你给的那份构建。** 每一轮都从 REAPER 进程的模块清单和 REAPER 自己的 `fx_ident` 两处证明：
  加载进来的插件二进制是你这份构建的私有副本，而不是系统里装着的同名发布版。
- **不会悄悄放行。** 结局只有 PASS、FAIL、INCOMPLETE（没有结论）、SKIPPED、REFUSED；INCOMPLETE 永远不算 PASS。
  内置反例每一轮都证明对拍器、看门狗和各道护栏仍然有效。
- **只在本机用。** 它驱动本机装好的 REAPER 7，需要真实的桌面会话；REAPER 的许可按 REAPER 自己的条款办理。
  它不是给托管的 CI runner 用的。它自己的自测不需要 REAPER，在哪里都能跑。

## 测什么

| kind | |
|---|---|
| `render` | 渲染一个布局（轨道、文件夹、发送、声像与静音、FX 链，参数按名字设定或用带名字的插件 state，每轨可有自己的测试信号），与干声渲染、重复渲染或一个变体（换块长、渲染方式、旁路或布局）比较，或者单独判定：逐位相同，或残差在限内；对齐偏移等于预期；可加峰值、静音和每声道电平与平衡检查；总输出之外任意轨道可单独导出成 stem |
| `device` | Dummy 设备按配置的块长、采样率和预测性 FX 处理设置运行；每个 FX 都已加载、不是 offline、报出预期的延迟，参数读回与设定一致，持有给它的那份 state |
| `savereopen` | 存盘再打开（一次或多次）后每个 FX、参数与 state 都不变，重开的工程渲染结果逐位相同 |
| `instances` | 反复加减实例，句柄与内存的增长不超过上限 |

工具自带一个很小的 JSFX：把信号延迟若干样本，并（按设定）把这段延迟报成插件延迟，用来测延迟补偿，不依赖 REAPER
自带的效果器。扩展可以加产品专用的 kind 和驱动步骤（[docs/EXTENDING.md](docs/EXTENDING.md)）。

## 快速开始

需要：Windows 10 或 11、PowerShell 7.4+、REAPER 7（x64）。

```powershell
# 一次性：建私有配置目录（永远不能在 %APPDATA% 下）
pwsh doctor.ps1 -CfgDir D:\reaper-harness\cfg -Init

# 检查配置文件和本机（不会启动 REAPER）
pwsh doctor.ps1 -CfgDir D:\reaper-harness\cfg -Config my-plugin.json -PluginDir D:\build\VST3

# 运行
pwsh run.ps1 -Config my-plugin.json -CfgDir D:\reaper-harness\cfg -PluginDir D:\build\VST3 -ResultDir D:\reaper-harness\results

# 工具自己的自测（不需要 REAPER）
pwsh run.ps1 -SelfTest
```

退出码：0 PASS，1 FAIL，2 INCOMPLETE，3 SKIPPED，64 被护栏拒绝或用法错误。

## 文档

文档正文是英文：

- [docs/USAGE.md](docs/USAGE.md)：怎么运行、各个参数、退出码
- [docs/CONFIG.md](docs/CONFIG.md)：配置文件；`schema/config.schema.json` 是它的 JSON Schema
- [docs/SAFETY.md](docs/SAFETY.md)：保证了什么、为什么
- [docs/RESULTS.md](docs/RESULTS.md)：结果文件
- [docs/EXTENDING.md](docs/EXTENDING.md)：扩展模块与 Lua 步骤

REAPER 是 Cockos Incorporated 的商标。本项目与 Cockos 没有关联，也未获其认可。

## 许可证

MIT，见 [LICENSE](LICENSE)。
