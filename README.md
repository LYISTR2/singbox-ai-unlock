# singbox-ai-unlock

One-click helper for routing selected AI service traffic from a sing-box VPS through a separate DNS + SNI unlock/exit VPS.

It has two modes:

- `unlock-server`: configure the exit VPS with `dnsmasq` + `nginx stream ssl_preread`.
- `singbox-client`: patch a sing-box config so AI domains resolve to the unlock VPS and route `direct`.

## Architecture

```text
User device
  -> sing-box VPS proxy port
  -> AI domain matched by sing-box route/DNS rules
  -> DNS query to unlock VPS :53
  -> AI domain resolves to unlock VPS IP
  -> TCP 443 direct to unlock VPS
  -> nginx stream reads TLS SNI and forwards to real upstream
```

## Quick start

You can run the script interactively and enter IPs when prompted, or pass them as flags.

### 1. On the unlock/exit VPS

Interactive:

```bash
wget -O ai_singbox_unlock_setup.sh https://raw.githubusercontent.com/LYISTR2/singbox-ai-unlock/main/ai_singbox_unlock_setup.sh
chmod +x ai_singbox_unlock_setup.sh
bash ai_singbox_unlock_setup.sh unlock-server
```

Non-interactive:

```bash
bash ai_singbox_unlock_setup.sh unlock-server --unlock-ip <UNLOCK_VPS_IP> --client-ip <SINGBOX_CLIENT_IP>
```

This will:

- install `dnsmasq`, `dnsutils`, `nginx`, `libnginx-mod-stream`;
- write `/etc/dnsmasq.d/custom_ai.conf`;
- disable broken `sniproxy` if present;
- configure nginx stream SNI forwarding on TCP 443;
- restrict `53/80/443` to the sing-box client IP unless `--no-firewall` is used.

### 2. On the sing-box VPS/client

Interactive:

```bash
wget -O ai_singbox_unlock_setup.sh https://raw.githubusercontent.com/LYISTR2/singbox-ai-unlock/main/ai_singbox_unlock_setup.sh
chmod +x ai_singbox_unlock_setup.sh
bash ai_singbox_unlock_setup.sh singbox-client
```

Non-interactive:

```bash
bash ai_singbox_unlock_setup.sh singbox-client --unlock-ip <UNLOCK_VPS_IP> --config /usr/local/etc/sing-box/config.json
```

This will:

- backup the sing-box config;
- add `ai-unlock-dns`;
- route selected AI domains to `direct`;
- block AI UDP/443 to avoid QUIC bypass;
- run `sing-box check`;
- restart `sing-box`.

By default the sing-box side uses TCP DNS:

```text
tcp://<unlock-ip>
```

If your unlock VPS allows UDP/53 and it works from the client VPS, you may use:

```bash
bash ai_singbox_unlock_setup.sh singbox-client --unlock-ip <UNLOCK_VPS_IP> --dns-transport udp
```

## Options

```text
unlock-server:
  --unlock-ip <EXIT_IP>      Public IP of the unlock VPS
  --client-ip <CLIENT_IP>    Public IP of the sing-box VPS/client allowed to use this unlock endpoint
  --no-firewall              Do not modify iptables
  --no-restart               Write configs but do not restart services

singbox-client:
  --unlock-ip <EXIT_IP>      Public IP of the unlock VPS
  --config <config.json>     sing-box config path, default /usr/local/etc/sing-box/config.json
  --relay-config <file>      optional second sing-box config path, default /usr/local/etc/sing-box/relay.json
  --dns-transport tcp|udp    default tcp
  --no-restart               Check config but do not restart sing-box
```

## AI domains included

- OpenAI / ChatGPT
- Claude / Anthropic
- Gemini / AI Studio
- Perplexity
- Poe
- Copilot/Bing

Edit the `AI_DOMAINS` array in the script if you need more domains.

## Notes

- DNS-only is not enough for source-IP unlock. The selected HTTPS traffic must also go through the unlock VPS TCP 443 SNI proxy.
- `sniproxy` packages on some distros are compiled without `libudns`, which breaks wildcard backends like `.* *`. This script uses `nginx stream ssl_preread` instead.
- Block UDP/443 for matched AI domains so clients fall back from QUIC/HTTP3 to TCP/TLS.
- Do not leave DNS or wildcard SNI proxy open to the whole internet.

## Rollback

The script creates timestamped backups before changing important files, for example:

```text
/usr/local/etc/sing-box/config.json.bak.YYYYMMDD-HHMMSS
/etc/nginx/nginx.conf.bak.YYYYMMDD-HHMMSS
/etc/dnsmasq.d/custom_ai.conf.bak.YYYYMMDD-HHMMSS
```

Restore the backup and restart the relevant service if needed.
