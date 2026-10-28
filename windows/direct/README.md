# Claude 专用 Windows 程序防直连

保留精确程序规则框架，不启用历史草稿的全网卡 IPv6 关闭、第二 TUN 或后台任务。不更改 Tailscale、WSL、现有 TUN、时区或防火墙全局默认策略。

ProgramDiscovery.ps1 每次动态发现已注册的官方 Claude 包、内嵌 Code 与独立 CLI。核验官方包身份、精确目录边界、无重解析点及 Anthropic 签名；未知则拒绝。发现的路径和指纹仅留在内存，不另存清单。个人参数统一由 ../local/Configuration.ps1 读取唯一的 ../local/settings.json，请在设置页保存。

规则组 ClaudeNoDirect-v1：每个程序各一条非回环 IPv4 / IPv6 出站阻断，所有协议与网络配置文件，覆盖 UDP，保留本机回环代理。它不限制其他程序，也不约束远端代理之后更换公网出口。

根目录 Apply-ClaudeNoDirect.cmd 应用，Undo-ClaudeNoDirect.cmd 撤销，需要 Windows 管理员授权。应用须与配置保存使用同一 Windows 账号，并先保存工作、完全退出 Claude / Cowork；不强制结束会话。正式应用前使用独立系统 curl 副本做相同规则的连接对照；缺少 IPv6 对照时，不把策略核对宣传为已完成公网 IPv6 验证。

status.json / network-test.json 仅保存状态、计数、公开版本与布尔结果，不保存 IP、SID、网卡清单、路径或原始异常。不再生成 apply.log、system-before.json 和程序路径清单。Windows 自身防火墙规则库仍须存储程序路径。正式规则会在 ActiveStore 中逐项核对程序、方向、动作、协议、地址范围及配置文件。

日常入口 Start-ClaudePreflight.cmd：核对有效规则、当前路径、代理、完整固定出口、TUN 和地区配对。TUN 必检 v2rayN 开关、生成配置、sing-box、指定 sing-tun 网卡、完整默认路由及两处实际选路；查询不发网络包，也不证明全部目标相同。启动前再次核对 TUN 和地区。

升级后“更新保护规则”核验新程序、申请 UAC、补齐规则并保留旧规则，应用期间版本变化则拒绝并回滚本次新增规则。修复动作不启动 Claude。未覆盖版本不能通过本启动器启动，但开机服务、其他入口或更新器不会经过本窗口，因此仍有升级空窗。

专用程序规则不继承给任意子工具、Python、Git、PowerShell、WSL、共享服务，也不阻止程序委托本机服务联网。未取消自动更新、未更改服务自启动、未安装持续监测。不要称为完整进程隔离、零泄漏或防封保证。
