# singbox-ai-unlock：sing-box AI 解锁分流一键脚本

这个仓库提供一个一键脚本，用来把 **sing-box 节点中的指定 AI 服务流量** 分流到另一台 **解锁/出口 VPS**。

适用场景：

- 你有一台 sing-box 节点 VPS，用户设备连这台节点；
- 你另有一台地区/IP 更适合访问 ChatGPT、Claude、Gemini 等服务的 VPS；
- 希望只有 AI 域名走解锁 VPS，其他网站仍然保持原来的 sing-box 出口；
- 不想把整台机器系统 DNS 全局改掉。

---

## 工作原理

```text
用户设备
  -> 连接 sing-box VPS 的代理端口
  -> sing-box 判断目标域名
  -> 普通网站：照旧直连或按你原来的规则走
  -> AI 域名：
       1. DNS 查询发到解锁 VPS
       2. AI 域名解析为解锁 VPS 的 IP
       3. TCP 443 直连解锁 VPS
       4. 解锁 VPS 上的 nginx stream 读取 TLS SNI
       5. nginx stream 按 SNI 转发到真实 AI 服务
```

重点：**DNS 只是把 AI 域名导向解锁 VPS，真正让目标服务看到解锁 VPS 出口 IP 的，是解锁 VPS 上的 TCP 443 SNI 转发。**

---

## 支持系统

当前脚本已测试/适配：

- Debian / Ubuntu：使用 `apt-get` + `systemd`
- Alpine Linux：使用 `apk` + OpenRC

如果你的系统不是上述类型，脚本会提示不支持。

---

## 一键下载脚本

在需要配置的 VPS 上执行：

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

## 部署步骤总览

需要在两台机器上分别执行：

1. **解锁端 VPS**：运行 `unlock-server` 模式；
2. **sing-box 客户端/节点 VPS**：运行 `singbox-client` 模式。

---

# 第一步：配置解锁端 VPS

在你准备用作 AI 出口的 VPS 上运行：

```bash
bash ai_singbox_unlock_setup.sh unlock-server
```

脚本会交互式询问：

```text
Enter unlock/exit VPS public IPv4:
Enter sing-box client VPS public IPv4 allowed to use this unlock endpoint:
```

含义：

- `unlock/exit VPS public IPv4`：当前这台解锁 VPS 的公网 IPv4；
- `sing-box client VPS public IPv4`：允许访问这个解锁端的 sing-box 节点 VPS 公网 IPv4。

脚本会做这些事：

- 安装 `dnsmasq`；
- 安装 `nginx` 和 `nginx stream` 模块；
- 生成 `/etc/dnsmasq.d/custom_ai.conf`；
- 让 AI 域名解析到解锁 VPS IP；
- 停用可能有问题的 `sniproxy`；
- 用 `nginx stream ssl_preread` 监听 TCP 443；
- 根据 TLS SNI 转发到真实目标域名；
- 默认用 iptables 限制只有 sing-box 客户端 IP 能访问 `53/80/443`；
- 如果系统支持，会持久化 iptables 规则。

## 解锁端非交互式用法

也可以直接带参数：

```bash
bash ai_singbox_unlock_setup.sh unlock-server \
  --unlock-ip <UNLOCK_VPS_IP> \
  --client-ip <SINGBOX_CLIENT_IP>
```

例如你以后自己替换成真实 IP 即可：

```bash
bash ai_singbox_unlock_setup.sh unlock-server \
  --unlock-ip <你的解锁端公网IP> \
  --client-ip <你的sing-box节点公网IP>
```

## 如果不想让脚本修改防火墙

```bash
bash ai_singbox_unlock_setup.sh unlock-server --no-firewall
```

如果使用 `--no-firewall`，请你自己确保：

- sing-box 客户端 VPS 可以访问解锁端 `53/tcp` 或 `53/udp`；
- sing-box 客户端 VPS 可以访问解锁端 `443/tcp`；
- 不要把 DNS 和通配 SNI 代理无限制暴露给全网。

---

# 第二步：配置 sing-box 客户端/节点 VPS

在运行 sing-box 节点的 VPS 上执行：

```bash
bash ai_singbox_unlock_setup.sh singbox-client
```

脚本会交互式询问：

```text
Enter unlock/exit VPS public IPv4:
sing-box config path [/usr/local/etc/sing-box/config.json]:
optional relay config path; leave default if present [/usr/local/etc/sing-box/relay.json]:
DNS transport to unlock VPS, tcp or udp [tcp]:
```

建议：

- 不确定 DNS 传输方式时直接回车，默认用 `tcp`；
- 如果你确认解锁端 UDP 53 对客户端可用，可以填 `udp`；
- 大多数 sing-box 安装脚本配置路径是 `/usr/local/etc/sing-box/config.json`，默认直接回车即可。

脚本会做这些事：

- 备份原 sing-box 配置；
- 添加 `ai-unlock-dns` DNS 服务器；
- 让 AI 域名 DNS 查询走解锁 VPS；
- 让 AI 域名连接走 `direct`；
- 阻断 AI 域名的 `UDP 443`，避免 QUIC / HTTP3 绕过 TCP SNI 代理；
- 执行 `sing-box check`；
- 重启 sing-box 服务。

## sing-box 客户端非交互式用法

```bash
bash ai_singbox_unlock_setup.sh singbox-client \
  --unlock-ip <UNLOCK_VPS_IP> \
  --config /usr/local/etc/sing-box/config.json
```

如果解锁端 DNS 使用 UDP：

```bash
bash ai_singbox_unlock_setup.sh singbox-client \
  --unlock-ip <UNLOCK_VPS_IP> \
  --dns-transport udp
```

---

## 完整参数说明

```text
unlock-server 模式：
  --unlock-ip <IP>       解锁端 VPS 公网 IPv4
  --client-ip <IP>       允许使用解锁端的 sing-box 节点公网 IPv4
  --no-firewall          不修改 iptables
  --no-restart           只写配置，不重启服务

singbox-client 模式：
  --unlock-ip <IP>       解锁端 VPS 公网 IPv4
  --config <路径>        sing-box 主配置路径，默认 /usr/local/etc/sing-box/config.json
  --relay-config <路径>  第二配置文件路径，默认 /usr/local/etc/sing-box/relay.json
  --dns-transport tcp|udp 访问解锁端 DNS 的方式，默认 tcp
  --no-restart           只修改并检查配置，不重启 sing-box
```

---

## 脚本内置的 AI 域名

当前包含：

```text
openai.com
chatgpt.com
auth.openai.com
auth0.openai.com
api.openai.com
oaistatic.com
oaiusercontent.com
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

如果后续发现某个服务资源加载不全，可以编辑脚本里的 `AI_DOMAINS` 数组再运行。

---

## 验证方法

## 在解锁端 VPS 上验证

```bash
ss -lntup | grep -E ':(53|80|443)\b'
```

应该能看到类似：

```text
dnsmasq 监听 53
nginx   监听 443
```

测试 DNS：

```bash
dig +tcp chatgpt.com @127.0.0.1 +short
dig +tcp claude.ai @127.0.0.1 +short
```

返回应该是你的解锁端 IP。

## 在 sing-box 客户端 VPS 上验证

测试能否连到解锁端 443：

```bash
timeout 5 bash -c '</dev/tcp/<UNLOCK_VPS_IP>/443' && echo ok
```

测试解锁端 DNS：

```bash
dig +tcp chatgpt.com @<UNLOCK_VPS_IP> +short
dig +tcp claude.ai @<UNLOCK_VPS_IP> +short
```

如果你使用 UDP DNS，则改成：

```bash
dig chatgpt.com @<UNLOCK_VPS_IP> +short
```

通过 sing-box 实际访问时，可以查看 sing-box 日志，应该能看到：

```text
inbound connection to chatgpt.com:443
router: match domain_suffix ... => route(direct)
dns: match domain_suffix ... => route(ai-unlock-dns)
A chatgpt.com -> <UNLOCK_VPS_IP>
```

如果 curl 返回类似下面内容，说明链路已经到 ChatGPT，只是触发了 Cloudflare 验证：

```text
HTTP/2 403
server: cloudflare
cf-mitigated: challenge
```

这不是网络失败。

---

## 回滚方法

脚本修改重要文件前会自动备份，例如：

```text
/usr/local/etc/sing-box/config.json.bak.YYYYMMDD-HHMMSS
/etc/nginx/nginx.conf.bak.YYYYMMDD-HHMMSS
/etc/dnsmasq.d/custom_ai.conf.bak.YYYYMMDD-HHMMSS
/etc/dnsmasq.conf.bak.YYYYMMDD-HHMMSS
```

需要回滚时，把对应备份复制回原路径，然后重启相关服务即可。

例如回滚 sing-box 配置：

```bash
cp /usr/local/etc/sing-box/config.json.bak.YYYYMMDD-HHMMSS /usr/local/etc/sing-box/config.json
systemctl restart sing-box
```

Alpine/OpenRC 系统则可能是：

```bash
rc-service sing-box restart
```

---

## 常见问题

## 1. 为什么不用 sniproxy？

一些发行版的 `sniproxy` 包没有编译 `libudns`，会导致通配后端配置失败，例如：

```text
Only socket address backends are permitted when compiled without libudns
```

所以脚本改用 `nginx stream ssl_preread`，更稳定。

## 2. 为什么要阻断 UDP 443？

浏览器和客户端可能使用 QUIC / HTTP3，也就是 UDP 443。

但 nginx stream SNI 转发处理的是 TCP 443。如果不阻断 UDP 443，部分请求可能绕过解锁链路。

所以脚本会在 sing-box 里对 AI 域名添加 UDP 443 block 规则。

## 3. 为什么默认 DNS 用 TCP？

有些 VPS 或防火墙环境下 UDP 53 容易被拦截，但 TCP 53 可用。

为了稳定，sing-box 客户端模式默认使用：

```text
tcp://<UNLOCK_VPS_IP>
```

如果你确认 UDP 53 可用，可以指定：

```bash
--dns-transport udp
```

## 4. 为什么访问 ChatGPT 仍然出现 Cloudflare 验证？

Cloudflare 验证页说明请求已经到达 ChatGPT/Cloudflare。是否触发验证取决于浏览器环境、IP 信誉、Cookie、指纹等因素，不代表分流失败。

## 5. 解锁端是否应该开放给全网？

不建议。

通配 SNI 转发如果开放给全网，可能被别人滥用。脚本默认会用 iptables 限制 `53/80/443` 只允许你指定的 sing-box 客户端 IP 访问。

---

## 安全建议

- 不要把 SSH 密码、GitHub Token 发到公开环境；
- 解锁端只放行可信客户端 IP；
- 如果客户端公网 IP 变化，需要重新运行 `unlock-server` 模式或手动更新 iptables；
- 建议使用 SSH key 登录 VPS，并关闭密码登录。
