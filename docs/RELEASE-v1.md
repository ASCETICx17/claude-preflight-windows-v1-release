# Claude Preflight v1

发布日期：2026-10-28。发布基线：v9.1。

本版沿用 v9.1 的检查条件、网络请求、DNS / WebRTC 黄色提醒、30 秒预算、程序防直连规则和配置结构。发布版本名称调整不增加功能，也不改变此前的验证范围。

## 本次整理

- 窗口标题为 Claude Preflight · v1，页眉标识为 V1。
- 日常启动只保留 Start-ClaudePreflight.cmd。内容重复的 Start-ClaudeSwitcher.cmd 已删除，相关现行指引已更新。
- docs 下 10 张图片全部删除：1 张上游截图、9 张本项目演示图。相关图片嵌入引用已清理；以后由作者自行补充真实截图。
- 根目录 README 已重新编写，包含运行要求、首次配置、必要检查、辅助观测、保护范围、更新撤销及开发验证。作者用的完整说明单独交付，不放入公开 ZIP。
- README 加入架构图和启动流程，明确 PowerShell / WPF、C# 与 JavaScript 的分工；时区与出口国家分别检查。
- 7 份内部历史发布说明（20,111 字节）移出公开目录，对外只保留本 v1 说明。历史验证结果仍在 VALIDATION.md 汇总。
- 5 个以 throw 禁用的严格模式入口（11,879 字节）移出公开目录。Test-LocalGuard.ps1 保留，它仍是统一测试入口调用的启动保护回归；StrictPolicy.ps1 中的现用公共函数也保留。
- 开发导出工具仍为 Export-PublicPreview.cmd，默认文件名更新为 claude-preflight-windows-v1.zip。
- schemaVersion 仍为 2，防火墙规则组仍为 ClaudeNoDirect-v1。这些兼容字段不随展示版本重命名。

## 如何使用

1. 解压项目，运行 Start-ClaudePreflight.cmd。
2. 已有配置可从自己正在使用的版本复制 windows/local/settings.json 到新版同一位置；公开 ZIP 不含此文件。
3. 初次使用在界面保存配置，按需通过 Apply-ClaudeNoDirect.cmd 或界面按钮更新保护规则。
4. 已配置代理、固定出口和 TUN 后重新检查，必要条件通过再点击启动 Claude。

普通用户无需 Python、Node.js、npm、.NET SDK 或独立 C# 编译器。Windows 当前入口使用 Windows PowerShell 5.1、系统 .NET Framework / WPF；WebRTC 观测调用已安装的 Edge。Node.js 只用于开发者运行 JavaScript 模拟测试；当前包已不含 Python、Swift 或 macOS/Linux Shell 实现。

## 未使用内容剥离

删除未被当前启动链调用的 app、assets、core、daemons、installer、linux、upstream-notes 目录，以及 windows 顶层旧 Beta 文件；同时移除早期来源统计、市场调研及旧文档归档。共移除 31 个文件，约 2.73 MB，其中包括 16 个原样引入的源码文件。

当前只保留 windows/local、windows/direct、tests、tools 和现行技术文档。原日常入口、配置格式、10 项必要检查、DNS / WebRTC 提醒及规则应用逻辑保持原样。当前没有账号切换、常驻守护或 macOS/Linux 适配；删除操作没有减少这些本来就未提供的功能。

StrictPolicy.ps1 是本项目开发时编写的兼容函数集合，固定 IP 比较函数仍被当前检查和网络观测调用，因此保留；它不导入已删除的旧平台实现。LICENSE 和简短 NOTICE 保留版权记录，不属于程序运行依赖。

本版仍要求官方应用包布局、现有 v2rayN / sing-box TUN、本机 HTTP 代理，以及应用规则时的管理员权限。详细检测过程见 [检测流程](DETECTION-WALKTHROUGH.md)。DNS / WebRTC 保持黄色提醒；WebRTC 使用独立临时 Edge 观察网络环境，不代表对 Claude 桌面进程完成了流量实测。固定出口在启动前检查，当前默认入口没有持续出口守护。

本次发布精简移除未使用入口，保留现用运行源码、全部测试和导出器；不进行现场联网复测或调整用户网络。发布包重新进行离线回归、私密文件排除和文件哈希核对。历史测试与现场验收范围见 [验证记录](VALIDATION.md)。
