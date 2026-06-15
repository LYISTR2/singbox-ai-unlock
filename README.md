# singbox-ai-unlock：sing-box AI 分流到 Shadowsocks 出口的一键脚本

这个仓库现在提供的是 **sing-box 客户端/节点侧分流脚本**。

它不再依赖：

- `dnsmasq` 把 AI 域名劫持到解锁端；
- `nginx stream` 按 SNI 透明转发；
- 解锁端额外部署 DNS + SNI 透明代理。

现在的新逻辑更直接：

```text
用户设备
  -> 连接你的 sing-box 节点 VPS
  -> sing-box 判断目标域名
  -> 普通网站：按你原来的出口规则走
  -> AI 域名：走你输入的 Shadowsocks 出口节点
```

这个方案更适合：

- ChatGPT App
- ChatGPT 网页版
- Claude
- Gemini
- 其他对 TLS / 证书 / App 网络环境更敏感的 AI 服务

因为它不再把 AI 域名解析成“解锁端 IP”，而是让连接正常解析真实域名，再通过 sing-box 的 Shadowsocks outbound 出站。

---

## 适用场景

适合你已经有：

- 一台 sing-box 节点 VPS；
- 一个可用的 Shadowsocks 节点，作为 AI 服务专用出口；
- 希望只有 AI 域名走这个 SS 出口，其他流量保持原样。

不适合：

- 你想自动部署解锁端的 `dnsmasq + nginx stream`；
- 你需要脚本帮你在出口 VPS 上搭建透明 SNI 代理。

这个仓库现在**不再做解锁端部署**，只负责 **sing-box 客户端/节点侧自动分流**。

---

## 工作原理

```text
用户设备
  -> 连入 sing-box 节点 VPS
  -> sing-box 匹配域名
  -> 普通流量：继续走原来的规则
  -> AI 域名：走新建的 Shadowsocks outbound
  -> 由你输入的 SS 节点作为出口访问 ChatGPT / Claude / Gemini
```

同时脚本会：

- 为 AI 域名添加路由规则；
- 阻断 AI 域名的 `UDP 443`；
- 强制这些域名回落到 TCP 443，避免 QUIC / HTTP3 绕过代理分流。

---

## 支持系统

当前脚本运行在 **sing-box 节点 VPS** 上，已按常见 Linux 环境设计：

- Debian / Ubuntu
- 其他能运行 `bash + python3 + sing-box` 的 Linux 系统

脚本本身不依赖包管理器安装组件，因为它不再负责搭解锁端服务。

要求环境里已有：

- `bash`
- `python3`
- `sing-box`

---

## 一键下载脚本

在你的 sing-box 节点 VPS 上执行：

```bash
wget -O ai_singbox_unlock_setup.sh https://raw.githubusercontent.com/LYISTR2/singbox-ai-unlock/main/ai_singbox_unlock_setup.sh
chmod +x ai_singbox_unlock_setup.sh
```

如果没有 `wget`，可以用：

```bash
curl -fsSL https://raw.githubusercontent.com/LYISTR2/singbox-ai-unlock/main/ai_singbox_unlock_setup.sh -o ai_singbox_unlock_setup.sh
chmod +x ai_singbox_unlock_setup.sh
```

---

## 你需要准备什么

你需要准备一个 **可用的 Shadowsocks 出口节点**。

脚本支持两种输入方式：

### 方式 1：直接输入完整 `ss://` 链接

例如：

```text
ss://BASE64编码内容@1.2.3.4:443#JP
```

或者常见的 SS2022 节点格式。

### 方式 2：手动输入 4 个参数

- `server`
- `port`
- `method`
- `password`

例如：

```text
server: 1.2.3.4
port: 20021
method: 2022-blake3-aes-256-gcm
password: xxxxxxxxxx
```

---

## 最常用用法：交互式运行

在 sing-box 节点 VPS 上执行：

```bash
bash ai_singbox_unlock_setup.sh singbox-client
```

脚本会依次询问：

```text
sing-box config path [/usr/local/etc/sing-box/config.json]:
optional relay config path; leave default if present [/usr/local/etc/sing-box/relay.json]:
AI outbound tag [ai-unlock-ss]:
optional outbound detour tag; leave empty for none:
Paste full ss:// node; leave empty to input manually:
```

如果你粘贴了完整 `ss://` 节点，脚本会自动解析：

- 服务器地址
- 端口
- 加密方式
- 密码

如果你把 `ss://` 留空，脚本会继续问你：

```text
Shadowsocks server / hostname:
Shadowsocks port:
Shadowsocks method (example: 2022-blake3-aes-256-gcm):
Shadowsocks password:
```

输入完成后，脚本会自动：

- 备份你的 sing-box 主配置；
- 删除旧的 `ai-unlock-dns` DNS 劫持规则；
- 新增一个 Shadowsocks outbound；
- 把 AI 域名改成走这个 outbound；
- 保留 AI 域名 `UDP 443 -> block` 规则；
- 执行 `sing-box check`；
- 重启 sing-box 服务。

---

## 非交互式用法

### 用完整 `ss://` 节点

```bash
bash ai_singbox_unlock_setup.sh singbox-client \
  --ss-url 'ss://BASE64@1.2.3.4:443#JP'
```

### 手动指定 Shadowsocks 参数

```bash
bash ai_singbox_unlock_setup.sh singbox-client \
  --server 1.2.3.4 \
  --port 20021 \
  --method 2022-blake3-aes-256-gcm \
  --password 'YOUR_PASSWORD'
```

### 指定 sing-box 配置文件路径

```bash
bash ai_singbox_unlock_setup.sh singbox-client \
  --ss-url 'ss://BASE64@1.2.3.4:443#JP' \
  --config /usr/local/etc/sing-box/config.json \
  --relay-config /usr/local/etc/sing-box/relay.json
```

### 指定 outbound tag

```bash
bash ai_singbox_unlock_setup.sh singbox-client \
  --ss-url 'ss://BASE64@1.2.3.4:443#JP' \
  --tag ai-jp-ss
```

### 指定 detour

如果你希望这个 SS outbound 自己再挂到某个已有出口 tag 上，可以加：

```bash
bash ai_singbox_unlock_setup.sh singbox-client \
  --ss-url 'ss://BASE64@1.2.3.4:443#JP' \
  --outbound-detour direct
```

大多数场景留空即可。

### 只改配置，不重启 sing-box

```bash
bash ai_singbox_unlock_setup.sh singbox-client \
  --ss-url 'ss://BASE64@1.2.3.4:443#JP' \
  --no-restart
```

适合你想先改好配置，自己手动检查后再重启。

---

## `parse-ss` 模式

如果你只是想检查某个 `ss://` 链接到底解析成什么，可以用：

```bash
bash ai_singbox_unlock_setup.sh parse-ss --ss-url 'ss://BASE64@1.2.3.4:443#JP'
```

脚本会输出：

```text
server=...
port=...
method=...
password=...
```

这个模式只做解析，不改任何配置。

---

## 脚本会修改什么

脚本只修改：

```text
你的 sing-box 主配置文件
```

默认是：

```text
/usr/local/etc/sing-box/config.json
```

修改前会自动备份，例如：

```text
/usr/local/etc/sing-box/config.json.bak.20260614-xxxxxx
```

---

## 脚本会自动清理的旧逻辑

如果你之前用过旧版 DNS 劫持 + SNI 解锁方案，脚本会自动清理：

- `ai-unlock-dns` 这个 DNS server；
- AI 域名走 `ai-unlock-dns` 的 DNS 规则；
- 旧的 AI 分流生成规则（`direct` / `block` / `ai-unlock-ss` 旧版本）。

也就是说，它会把仓库旧方案迁移成现在的新方案。

---

## 内置 AI 域名列表

当前脚本内置以下域名：

```text
openai.com
chatgpt.com
chat.openai.com
auth.openai.com
auth0.openai.com
api.openai.com
oaistatic.com
cdn.oaistatic.com
persistent.oaistatic.com
oaiusercontent.com
files.oaiusercontent.com
featuregates.org
statsig.com
statsigapi.net
intercom.io
intercomcdn.com

anthropic.com
api.anthropic.com
claude.ai
console.anthropic.com

gemini.google.com
generativelanguage.googleapis.com
ai.google.dev
aistudio.google.com

perplexity.ai
poe.com
copilot.microsoft.com
bing.com
edgeservices.bing.com
```

如果以后你发现某个服务资源没走代理，可以编辑脚本里的数组后重新运行。

---

## 验证方法

### 1. 检查 sing-box 配置是否通过

脚本运行时会自动执行：

```bash
sing-box check -c <config> [-c <relay-config>]
```

如果这里报错，说明配置没通过，脚本会直接停止。

---

### 2. 检查 Shadowsocks 节点端口是否可达

脚本运行时会自动测试：

```bash
TCP <port> open on <server>
```

如果看到：

```text
Cannot reach <server>:<port>
```

说明你的 sing-box 节点 VPS 当前访问不到这个 SS 节点。

---

### 3. 查看 sing-box 日志

你可以手动查看：

```bash
journalctl -u sing-box -f
```

当客户端访问 ChatGPT / Claude / Gemini 时，应该能看到类似：

```text
router: match domain_suffix=[openai.com chatgpt.com ...] => route(ai-unlock-ss)
outbound/shadowsocks[ai-unlock-ss]: outbound connection to chatgpt.com:443
```

如果你自定义了 `--tag`，日志里会显示你自己的 tag 名称。

---

### 4. 实际访问测试

客户端连到你的 sing-box 节点后，直接访问：

```text
https://chatgpt.com
https://claude.ai
https://gemini.google.com
```

如果网页能打开或至少返回真实站点响应，而不是本地网络错误，就说明分流已经生效。

对于 ChatGPT，常见正确现象是返回 Cloudflare challenge，例如：

```text
HTTP/2 403
server: cloudflare
cf-mitigated: challenge
```

这通常表示链路已经走通，只是 Cloudflare 触发了风控挑战，不是节点本身失败。

---

## 回滚方法

如果你想回滚到脚本执行前状态：

1. 找到脚本生成的备份文件；
2. 覆盖回原配置；
3. 重启 sing-box。

例如：

```bash
cp /usr/local/etc/sing-box/config.json.bak.20260614-xxxxxx /usr/local/etc/sing-box/config.json
systemctl restart sing-box
```

---

## 常见问题

### 1. 为什么现在不再做 DNS 劫持 + nginx SNI？

因为这个方案对网页版有时可用，但对 App，尤其是 ChatGPT App，容易出现：

- SSL 证书异常；
- 网络配置错误；
- 某些子域名没覆盖完全；
- QUIC / HTTP3 绕过；
- App 比浏览器更严格的证书和网络检查。

Shadowsocks 出口分流更直接，也更稳定。

---

### 2. 为什么还要阻断 UDP 443？

因为很多 App / 浏览器会优先尝试 HTTP/3 / QUIC。

如果 AI 域名走了 UDP 443，可能绕开你配置的 TCP 代理分流逻辑。所以脚本保留：

```text
AI 域名 + UDP 443 -> block
```

让它回落到 TCP 443。

---

### 3. 如果我的 SS 节点不是直接公网出口，而是另一个链式出口怎么办？

可以尝试给 outbound 加上：

```bash
--outbound-detour <已有tag>
```

但这取决于你自己的 sing-box 架构。大多数情况下不需要。

---

### 4. 脚本支持 VLESS / Trojan / Hysteria 吗？

当前版本只支持：

```text
Shadowsocks
```

尤其是标准 `ss://` 链接和 SS2022 参数。

如果你后续需要扩展到 VLESS / Trojan，可以再加解析和 outbound 生成逻辑。

---

### 5. `parse-ss` 输出了密码，这安全吗？

`parse-ss` 本来就是调试模式，会把节点内容直接解析显示出来。所以：

- 只在你自己机器上用；
- 不要把输出贴到公开地方；
- 不要把真实节点写进 GitHub README。

---

## 安全建议

- 不要把真实 `ss://` 节点直接写进公开仓库；
- 不要把真实 IP、密码、token、私钥写进 README；
- 调试完记得检查 shell 历史记录里有没有敏感命令；
- 如果某个节点已经在聊天中泄露，建议后续更换密码或整条节点。

---

## 当前仓库定位

这个仓库现在的定位很明确：

```text
不负责搭出口 VPS；
只负责把 sing-box 节点中的 AI 域名自动分流到你输入的 Shadowsocks 出口。
```

如果你已经有可用的 SS 出口节点，这个脚本就能直接拿来用。
