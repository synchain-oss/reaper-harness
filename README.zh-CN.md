# reaper-harness

在 Windows 上用 REAPER 无人值守地测试 VST3 插件：渲染对拍（null test）、旁路、存盘重开、反复加减实例。
每次运行都用一份私有的、隔离的 REAPER 配置，不会碰你自己的 REAPER 设置。

> **状态：** 开发中。还没有发布任何版本，命令行参数和配置文件格式都可能变。

[English](README.md)

- **每个插件项目一份配置文件。** 项目在里面列出自己的插件、轨道布局和测试场景；工具据此生成 REAPER 工程，
  经 Lua 脚本驱动 REAPER 渲染，再逐个样本比较渲染结果。
- **默认安全。** REAPER 走 Dummy 音频设备，用私有配置目录。这个目录有可能是 REAPER 的默认资源目录时，
  工具拒绝启动；只结束自己启动的进程；每轮前后都核对默认资源目录没有被改动。
- **只在本机用。** 它驱动本机装好的 REAPER 7，需要真实的桌面会话；REAPER 的许可按 REAPER 自己的条款办理。
  它不是给托管的 CI runner 用的。它自己的自测不需要 REAPER，在哪里都能跑。

## 目前有什么

安全底座与对拍器：私有配置目录的护栏、启动 REAPER 的进程宿主（看门狗、对话框处理、模块清单）、GUI 锁和
WAV 对拍器，各自带自测。场景和运行它们的命令随后加入。保证了什么、为什么，见 [docs/SAFETY.md](docs/SAFETY.md)（英文）。

需要：Windows 10 或 11、PowerShell 7.4+。

```powershell
# 私有配置目录（永远不能在 %APPDATA% 下）
pwsh doctor.ps1 -CfgDir D:\reaper-harness\cfg -Init

# 自测（不需要 REAPER）
pwsh run.ps1 -SelfTest
```

REAPER 是 Cockos Incorporated 的商标。本项目与 Cockos 没有关联，也未获其认可。

## 许可证

MIT，见 [LICENSE](LICENSE)。
