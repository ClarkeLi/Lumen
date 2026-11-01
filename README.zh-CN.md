<div align="center">

<img src="docs/banner.png" alt="Lumen – Claude Code 红绿灯" width="100%">

# Lumen

**Claude Code 的悬浮红绿灯，外加实时的剩余额度仪表。**

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)](#系统要求)
[![Swift](https://img.shields.io/badge/Swift-single%20file-orange)](Sources/main.swift)
[![Build](https://github.com/ClarkeLi/Lumen/actions/workflows/build.yml/badge.svg)](https://github.com/ClarkeLi/Lumen/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[English](README.md) · 简体中文 · [Deutsch](README.de.md)

</div>

Lumen 置顶悬浮在所有窗口之上（同时在菜单栏显示），一眼看清 Claude Code 此刻在做什么——它干活时你可以放心去做别的事，它需要你时刚好回来。红绿灯下方的小面板显示订阅 **5 小时 / 7 天**窗口的**剩余**额度。

<div align="center">
<img src="docs/states.png" alt="Lumen 的四种状态：工作中、需要你、等待输入、空闲" width="100%">
</div>

## 特性

- **置顶红绿灯** + 菜单栏图标，可拖动，自动记住位置
- **四种状态**由 Claude Code hooks 驱动，无需轮询终端输出
- **多会话感知**：同时运行多个会话时，取最紧急的一个（🟡 > 🔴 > 🟢）
- **额度仪表**：5h / 7d 窗口的剩余百分比，进度条按剩余量变色，并显示重置时间
- 三种大小、开机启动、一键卸载 hooks、零依赖

| 灯 | 含义 | 触发 |
|---|---|---|
| 🔴 | 工作中 | `UserPromptSubmit`、`PreToolUse`、`PostToolUse` |
| 🟡（闪烁） | 需要人介入 | `PermissionRequest`、权限通知、`AskUserQuestion`、`ExitPlanMode` |
| 🟢 | 任务停止，等待输入 | `Stop`、`SessionStart`、用户按 Esc 中断 |
| ⚪️ | 没有运行中的 Claude Code | – |

## 安装

```sh
git clone https://github.com/ClarkeLi/Lumen.git
cd Lumen
./build.sh --install   # 编译、复制到 ~/Applications 并启动
```

首次启动会自动把 hooks 写入 `~/.claude/settings.json`（原文件备份为 `settings.json.trafficlight-backup`）。新开的 Claude Code 会话即可被识别。

## 使用

- 拖动红绿灯可移动位置；右键红绿灯 = 菜单栏菜单
- 菜单栏：开启/关闭、显示/隐藏悬浮灯、显示/隐藏额度、大小、开机启动、卸载 hooks、退出

## 额度仪表

仪表显示的是**剩余**而不是已用：

- 进度条颜色：剩余 > 40% 绿，15–40% 黄，< 15% 红；`--` 表示还没拿到数据；数据超过 10 分钟没更新会变暗
- 鼠标悬停红绿灯或打开菜单，可看到各窗口的重置时间
- **数据来源**：每 3 分钟从 macOS 钥匙串读取 Claude Code 的 OAuth 凭证（`Claude Code-credentials`），请求 `api.anthropic.com/api/oauth/usage`。这是**非公开接口**，随时可能变动或失效。凭证只用于这次请求，不会保存
- 首次读取钥匙串时 macOS 可能弹窗，选「始终允许」即可
- 在菜单中关闭「显示额度」后，Lumen 恢复为纯红绿灯，也不再发任何请求

## 系统要求

- macOS 13+，Xcode Command Line Tools（`xcode-select --install`）
- 无第三方依赖，整个应用只有 `Sources/main.swift` 一个文件
- `./build.sh` 构建通用二进制（Apple 芯片 + Intel）到 `build/`；`./build.sh --install` 同时安装

## 隐私与免责

- 所有状态数据只保存在本机 `~/.claude/traffic-light/`
- 额度功能只会访问 `api.anthropic.com`
- Lumen 是非官方的社区项目，与 Anthropic 无关；Claude 是 Anthropic 的商标

## 许可证

[MIT](LICENSE) © Clarke Li
