# IP 风险评分与网页检测

核实日期：2026-10-22。自动评分不需要作者密钥，不部署共享后端，不保存查询历史。

## 当前选择

- **IPQuery 自动风险评分**：GET https://api.ipquery.io/{ip}。官方提供免注册、免 Key 查询；risk.risk_score 为 0–100，风险越高分越高。明确标注“风险评分，越低越好，建议优先选 0”；机房、VPN、代理等属性独立显示，0 分也不等于 Claude 信任或可用。
- **IPinfo.CV 网页入口**：https://ipinfo.cv/claude-ai-check 。尚未找到可核实的免费公开评分 API / 第三方调用约定，本次自动读取网页返回 HTTP 403。保留打开浏览器人工查看，不绕过站点验证，不抓网页伪装为 API。
- **IP99 自动评分已移除**：它的 0 分表示没有当前可核实证据，不能区分用户关心的“机房但无恶意证据”和“适合 Claude”。不再请求它的 API，也不连接其 MCP。

[IPQuery 官方文档](https://ipquery.io/) · [IPinfo.CV 检测页](https://ipinfo.cv/claude-ai-check)。

“网页可打开”与“提供免费公开 API”是两个问题。没有确认的能力不放进自动评分面板，不把未知显示为数字。

## 三个专项网页入口

| 按钮 | 地址与行为 | 分数方向 |
|---|---|---|
| Claude 信任评分 | https://ip.net.coffee/claude/ ，检测浏览器当前网络 | 高分代表更可信，以该站标注为准 |
| IP 纯净度检测 | https://iprisk.top/?lang=zh ，手动查询 / 查看 | 纯净度通常高分更好 |
| 欺诈评分 | https://scamalytics.com/ip/{saved-ip} ，自动附上已保存的固定 IP | 低分更好 |

四站统一排列在右侧 2×2 方框，整张卡可点击；原顶部单独按钮已移入卡片。外链仅在用户点击时打开。Scamalytics 不使用尚未保存的表单值或临时测试目标；固定 IP 仍经唯一配置入口读取。

外部网页遵循默认浏览器自己的代理设置，可能与本工具输入的测试 IP 不同，必须核对页面显示的 IP。本工具对 API 使用显式代理的约束，不等于接管默认浏览器全部流量。

[Net.Coffee 检测页](https://ip.net.coffee/claude/) · [IPRisk](https://iprisk.top/?lang=zh) · [Scamalytics](https://scamalytics.com/ip)。

## 如何测试机房 IP

不改启动用的固定出口。在“IP 质量”输入目标公网 IP 或含 IP 的报告链接，然后点击“查询风险评分”。只提取目标 IP，不访问粘贴地址、不解析其主机、不转发 token 和其余参数。

风险 / 欺诈分建议尽量低，信任 / 纯净度分看高，不能让所有网站分数一律为 0。机房 IP 得到低风险分并不矛盾：公开滥用记录、服务商网络属性和 Claude 自己的判断并非同一个指标。界面不会把风险分直接换算成 Claude 封号概率，也不会据此放行或阻止启动。

## 请求与隐私边界

IpQuality.ps1 负责输入和结果校验，NetworkRequests.ps1 负责异步 HTTP。只向内置 IPQuery HTTPS 目的地发请求；每项 8 秒超时、256 KiB 响应上限、禁止重定向、Cookie 和默认账号凭据；显式使用配置中的本机 HTTP 代理，不回退直连。

校验返回目标 IP 与数字分数；缺失、错误类型、越界或格式错误都显示不可用。没有作者账号、中转后端、API Key、自动轮询或查询历史。测试目标及结果留在内存，不替换保存的固定出口。

IPQuery 可以看到查询 IP、代理出口、时间与常规 HTTP 头；匿名不等于服务端没有记录，免费也不保证无限可用。没有发送 Claude 登录凭据、对话、设备标识或本地文件。

## 商业 API 与开源

Scamalytics 的 API 即使使用免费档仍需用户名与 Key。开源客户端可以让每位用户自行配置 Key；把作者真实 Key 放进 GitHub 则会公开同一账号的调用权限，让别人消耗作者额度。公开中转即使隐藏 Key，仍需限流与维护。本版没有部署这一方案。

IPRisk 的程序接口需方案与 Key；网页跳转并不等于自动调用其付费 API。

[Scamalytics 鉴权文档](https://docs.scamalytics.com/ip-fraud-risk-api/v3/) · [IPRisk API](https://iprisk.top/api?lang=zh)。

## 验证

34 项 IP 评分离线断言覆盖输入、隐私边界、缺失分数、机房提示和错误处理。2026-10-22 通过生产模块及已保存的显式代理查询公开测试地址 8.8.8.8，IPQuery 返回有效结果。自动流程没有请求 IP99、IPinfo.CV 或这三家人工网站；IPinfo.CV 的独立页面可达性核实得到 403。完整记录见 [VALIDATION](VALIDATION.md)。
