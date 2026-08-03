# singbox-ai-unlock

把指定的 AI 域名通过现有 sing-box 节点中的一个 Shadowsocks 出口转发。

脚本只做这一件事，不安装 sing-box，也不部署 DNS 劫持、Nginx SNI 或出口服务器。

## 作用

```text
普通流量 ──> 保持原有 sing-box 路由
AI 域名  ──> ai-unlock-ss Shadowsocks outbound
UDP/443  ──> 拒绝，强制回落 TCP，避免 QUIC 绕过
```

内置支持：ChatGPT/OpenAI、Claude、Gemini、Grok、Perplexity、Poe、Copilot 等常用域名。

## 一键使用

已经是 root 用户时，可以直接一行运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/LYISTR2/singbox-ai-unlock/main/ai_singbox_unlock.sh)
```

非 root 用户建议下载后使用 sudo：

下载：

```bash
curl -fsSL https://raw.githubusercontent.com/LYISTR2/singbox-ai-unlock/main/ai_singbox_unlock.sh -o ai_singbox_unlock.sh
```

运行后粘贴 `ss://` 节点，密码输入不会回显：

```bash
sudo bash ai_singbox_unlock.sh
```

也可以非交互运行。为了避免节点出现在 shell 历史中，推荐环境变量：

```bash
sudo env SS_URL='ss://...' bash ai_singbox_unlock.sh
```

## 自动识别

脚本会自动识别：

- `sing-box` 二进制位置；
- sing-box 版本，自动兼容 1.11+ 和旧版规则语法；
- `sing-box.service` / `singbox.service`；
- systemd `ExecStart` 中的 `-c`、`--config`、`-C`、`--config-directory`；
- 常见配置路径：
  - `/usr/local/etc/sing-box/config.json`
  - `/etc/sing-box/config.json`
  - `/etc/singbox/config.json`
  - `/opt/sing-box/config.json`

无法识别时可以手动指定：

```bash
sudo env SS_URL='ss://...' bash ai_singbox_unlock.sh \
  --config /path/to/config.json \
  --service sing-box
```

## 安全流程

正式配置不会先写后验。实际流程是：

1. 在临时目录生成新配置；
2. 用与 systemd 服务相同的全部配置文件执行 `sing-box check`；
3. 检查通过后创建唯一备份；
4. 同目录原子替换正式配置；
5. 重启并等待服务变为 active；
6. 重启失败时恢复原配置并再次启动原服务。

备份格式：

```text
config.json.bak.YYYYMMDD-HHMMSS.XXXXXX
```

只保留最近 5 份。

## 参数

```text
--ss-url <ss://...>       Shadowsocks URL
--config <path>           手动指定要修改的 JSON 配置
--service <unit>          手动指定 systemd 服务名
--add-domain <a,b,...>    追加 AI 域名后缀，可重复使用
--dry-run                 只显示 diff，不写入、不重启
--no-restart              写入并校验，但不重启
-h, --help                帮助
```

示例：

```bash
sudo env SS_URL='ss://...' bash ai_singbox_unlock.sh \
  --add-domain mistral.ai,meta.ai
```

预览配置差异：

```bash
sudo env SS_URL='ss://...' bash ai_singbox_unlock.sh --dry-run
```

## 保持不变的内容

脚本不会：

- 设置或修改 `route.final`；
- 添加 `direct` outbound；
- 删除仅因包含 AI 域名而被识别的用户自定义规则；
- 修改 DNS 配置；
- 修改其他已有 outbound；
- 输出 Shadowsocks 密码。

重复执行是幂等的，只会更新固定 tag：

```text
ai-unlock-ss
```

## 支持的 SS URL

支持：

- SIP002 明文 userinfo；
- base64 userinfo；
- 整段 base64；
- IPv4、域名和 `[IPv6]:port`；
- SS2022 方法。

不支持 SIP003 `plugin=` 参数。

## 测试

仓库自带无网络、无真实 systemd 副作用的 mock 测试：

```bash
bash tests/test.sh
```

测试覆盖自动发现、多配置检查、普通路由保持、幂等、自定义域名更新、dry-run 密码脱敏、检查失败、重启失败原子恢复、同秒备份、旧版语法、IPv6 和密码不泄漏。
