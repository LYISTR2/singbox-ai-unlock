#!/usr/bin/env bash
set -Eeuo pipefail

# AI sing-box unlock helper
# Modes:
#   unlock-server  : configure dnsmasq + nginx stream SNI proxy on the exit/unlock VPS
#   singbox-client : patch sing-box client/server config so selected AI domains resolve to unlock VPS and route direct
#
# Example:
#   bash ai_singbox_unlock_setup.sh unlock-server --unlock-ip 23.147.232.116 --client-ip 103.97.175.188
#   bash ai_singbox_unlock_setup.sh singbox-client --unlock-ip 23.147.232.116 --config /usr/local/etc/sing-box/config.json

SCRIPT_NAME="$(basename "$0")"
MODE=""
UNLOCK_IP=""
CLIENT_IP=""
SINGBOX_CONFIG="/usr/local/etc/sing-box/config.json"
SINGBOX_RELAY_CONFIG="/usr/local/etc/sing-box/relay.json"
NO_FIREWALL=0
NO_RESTART=0
DNS_TRANSPORT="tcp"   # tcp is safer when UDP/53 is filtered; values: tcp|udp

AI_DOMAINS=(
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
)

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME unlock-server  --unlock-ip <EXIT_IP> --client-ip <CLIENT_IP> [--no-firewall] [--no-restart]
  $SCRIPT_NAME singbox-client --unlock-ip <EXIT_IP> [--config <config.json>] [--relay-config <relay.json>] [--dns-transport tcp|udp] [--no-restart]

Modes:
  unlock-server
    Configure the exit VPS:
      - install dnsmasq, dnsutils, nginx, libnginx-mod-stream
      - write /etc/dnsmasq.d/custom_ai.conf so AI domains resolve to EXIT_IP
      - disable broken sniproxy, replace with nginx stream ssl_preread SNI proxy on 443
      - optionally restrict 53/80/443 to CLIENT_IP using iptables and persist rules if possible

  singbox-client
    Patch a sing-box config:
      - add DNS server ai-unlock-dns => tcp://EXIT_IP or udp://EXIT_IP
      - DNS-rule AI domains to ai-unlock-dns
      - route AI domains to direct
      - block AI UDP/443 to avoid QUIC bypass
      - backup original config before editing

Examples:
  # On unlock VPS / exit VPS:
  bash $SCRIPT_NAME unlock-server --unlock-ip 23.147.232.116 --client-ip 103.97.175.188

  # On sing-box client/server VPS:
  bash $SCRIPT_NAME singbox-client --unlock-ip 23.147.232.116 --config /usr/local/etc/sing-box/config.json

  # If your unlock DNS supports UDP/53 from the client:
  bash $SCRIPT_NAME singbox-client --unlock-ip 23.147.232.116 --dns-transport udp
EOF
}

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Please run as root."
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

valid_ipish() {
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]
}

parse_args() {
  [[ $# -gt 0 ]] || { usage; exit 1; }
  MODE="$1"; shift
  case "$MODE" in
    unlock-server|singbox-client) ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage; die "Unknown mode: $MODE" ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --unlock-ip) UNLOCK_IP="${2:-}"; shift 2 ;;
      --client-ip) CLIENT_IP="${2:-}"; shift 2 ;;
      --config) SINGBOX_CONFIG="${2:-}"; shift 2 ;;
      --relay-config) SINGBOX_RELAY_CONFIG="${2:-}"; shift 2 ;;
      --dns-transport) DNS_TRANSPORT="${2:-}"; shift 2 ;;
      --no-firewall) NO_FIREWALL=1; shift ;;
      --no-restart) NO_RESTART=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "Unknown argument: $1" ;;
    esac
  done

  [[ -n "$UNLOCK_IP" ]] || die "--unlock-ip is required."
  valid_ipish "$UNLOCK_IP" || die "--unlock-ip must be an IPv4 address."
  [[ "$DNS_TRANSPORT" == "tcp" || "$DNS_TRANSPORT" == "udp" ]] || die "--dns-transport must be tcp or udp."

  if [[ "$MODE" == "unlock-server" ]]; then
    [[ -n "$CLIENT_IP" ]] || die "unlock-server mode requires --client-ip."
    valid_ipish "$CLIENT_IP" || die "--client-ip must be an IPv4 address."
  fi
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  log "Installing packages: $*"
  apt-get update
  apt-get install -y "$@"
}

backup_file() {
  local f="$1"
  if [[ -e "$f" ]]; then
    local bak="${f}.bak.$(date -u +%Y%m%d-%H%M%S)"
    cp -a "$f" "$bak"
    log "Backed up $f -> $bak"
  fi
}

configure_dnsmasq_ai() {
  apt_install dnsmasq dnsutils curl
  mkdir -p /etc/dnsmasq.d
  backup_file /etc/dnsmasq.d/custom_ai.conf

  {
    echo "# Managed by $SCRIPT_NAME on $(date -u +%FT%TZ)"
    echo "# AI domains resolve to unlock IP: $UNLOCK_IP"
    for d in "${AI_DOMAINS[@]}"; do
      echo "address=/$d/$UNLOCK_IP"
    done
  } > /etc/dnsmasq.d/custom_ai.conf

  dnsmasq --test
  if [[ "$NO_RESTART" -eq 0 ]]; then
    systemctl enable dnsmasq >/dev/null || true
    systemctl restart dnsmasq
  fi
  log "dnsmasq AI rules written to /etc/dnsmasq.d/custom_ai.conf"
}

configure_nginx_stream() {
  apt_install nginx libnginx-mod-stream curl

  if systemctl list-unit-files sniproxy.service >/dev/null 2>&1; then
    warn "Disabling sniproxy; nginx stream will replace it for SNI forwarding."
    systemctl disable --now sniproxy || true
  fi

  backup_file /etc/nginx/nginx.conf
  mkdir -p /etc/nginx/stream-conf.d

  python3 - <<'PY'
from pathlib import Path
p = Path('/etc/nginx/nginx.conf')
s = p.read_text()
line = 'include /etc/nginx/stream-conf.d/*.conf;'
if line not in s:
    p.write_text(s.rstrip() + '\n\n# SNI unlock stream configs\n' + line + '\n')
PY

  cat > /etc/nginx/stream-conf.d/ai-unlock.conf <<'EOF'
stream {
    resolver 1.1.1.1 8.8.8.8 valid=300s ipv6=off;
    resolver_timeout 5s;

    log_format sni_unlock '$remote_addr [$time_local] $ssl_preread_server_name -> $upstream_addr status=$status sent=$bytes_sent received=$bytes_received time=$session_time';
    access_log /var/log/nginx/sni-unlock-access.log sni_unlock;
    error_log /var/log/nginx/sni-unlock-error.log notice;

    server {
        listen 0.0.0.0:443 reuseport;
        ssl_preread on;
        proxy_connect_timeout 10s;
        proxy_timeout 300s;
        proxy_pass $ssl_preread_server_name:443;
    }
}
EOF

  nginx -t
  if [[ "$NO_RESTART" -eq 0 ]]; then
    systemctl enable nginx >/dev/null || true
    systemctl restart nginx
  fi
  log "nginx stream SNI proxy configured on 0.0.0.0:443"
}

configure_firewall_unlock() {
  [[ "$NO_FIREWALL" -eq 0 ]] || { warn "Skipping firewall changes due to --no-firewall"; return; }
  need_cmd iptables

  log "Restricting 53/80/443 to client IP $CLIENT_IP using iptables. SSH is not touched."
  iptables -C INPUT -p tcp -s "$CLIENT_IP" --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp -s "$CLIENT_IP" --dport 443 -j ACCEPT
  iptables -C INPUT -p tcp -s "$CLIENT_IP" --dport 80  -j ACCEPT 2>/dev/null || iptables -I INPUT 2 -p tcp -s "$CLIENT_IP" --dport 80  -j ACCEPT
  iptables -C INPUT -p tcp -s "$CLIENT_IP" --dport 53  -j ACCEPT 2>/dev/null || iptables -I INPUT 3 -p tcp -s "$CLIENT_IP" --dport 53  -j ACCEPT
  iptables -C INPUT -p udp -s "$CLIENT_IP" --dport 53  -j ACCEPT 2>/dev/null || iptables -I INPUT 4 -p udp -s "$CLIENT_IP" --dport 53  -j ACCEPT

  iptables -C INPUT -p tcp --dport 443 -j DROP 2>/dev/null || iptables -I INPUT 5 -p tcp --dport 443 -j DROP
  iptables -C INPUT -p tcp --dport 80  -j DROP 2>/dev/null || iptables -I INPUT 6 -p tcp --dport 80  -j DROP
  iptables -C INPUT -p tcp --dport 53  -j DROP 2>/dev/null || iptables -I INPUT 7 -p tcp --dport 53  -j DROP
  iptables -C INPUT -p udp --dport 53  -j DROP 2>/dev/null || iptables -I INPUT 8 -p udp --dport 53  -j DROP

  if command -v netfilter-persistent >/dev/null 2>&1; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    log "iptables rules persisted to /etc/iptables/rules.v4"
  elif [[ -d /etc/iptables ]]; then
    iptables-save > /etc/iptables/rules.v4
    log "iptables rules saved to /etc/iptables/rules.v4"
  else
    warn "iptables rules applied but not persisted; install iptables-persistent if needed."
  fi
}

verify_unlock_server() {
  log "Listeners:"
  ss -lntup | grep -E ':(53|80|443)\b' || true

  if command -v dig >/dev/null 2>&1; then
    log "Local DNS verification:"
    dig +time=3 +tries=1 chatgpt.com @127.0.0.1 +short || true
    dig +time=3 +tries=1 claude.ai @127.0.0.1 +short || true
  fi

  log "Service status summary:"
  systemctl is-active dnsmasq || true
  systemctl is-active nginx || true
}

patch_singbox_client() {
  need_cmd python3
  [[ -f "$SINGBOX_CONFIG" ]] || die "sing-box config not found: $SINGBOX_CONFIG"
  backup_file "$SINGBOX_CONFIG"

  local dns_addr
  if [[ "$DNS_TRANSPORT" == "tcp" ]]; then
    dns_addr="tcp://$UNLOCK_IP"
  else
    dns_addr="udp://$UNLOCK_IP"
  fi

  AI_DOMAINS_STR="$(printf '%s\n' "${AI_DOMAINS[@]}")" \
  UNLOCK_DNS_ADDR="$dns_addr" \
  SINGBOX_CONFIG="$SINGBOX_CONFIG" \
  python3 - <<'PY'
import json, os, pathlib
path = pathlib.Path(os.environ['SINGBOX_CONFIG'])
conf = json.loads(path.read_text())
ai_domains = [x.strip() for x in os.environ['AI_DOMAINS_STR'].splitlines() if x.strip()]
dns_addr = os.environ['UNLOCK_DNS_ADDR']

# DNS section
dns = conf.setdefault('dns', {})
servers = dns.setdefault('servers', [])
servers = [s for s in servers if s.get('tag') != 'ai-unlock-dns']
servers.append({'tag': 'ai-unlock-dns', 'address': dns_addr, 'detour': 'direct'})
dns['servers'] = servers

rules = dns.setdefault('rules', [])
# remove prior generated rule by server tag
rules = [r for r in rules if r.get('server') != 'ai-unlock-dns']
rules.insert(0, {'domain_suffix': ai_domains, 'server': 'ai-unlock-dns'})
dns['rules'] = rules
dns.setdefault('strategy', 'ipv4_only')

# Outbounds: direct + block
outbounds = conf.setdefault('outbounds', [])
if not any(o.get('tag') == 'direct' for o in outbounds):
    outbounds.insert(0, {'type': 'direct', 'tag': 'direct'})
if not any(o.get('tag') == 'block' for o in outbounds):
    outbounds.append({'type': 'block', 'tag': 'block'})

# Route rules: block AI UDP/443, then AI direct
route = conf.setdefault('route', {})
rrules = route.setdefault('rules', [])
# remove old rules with exactly same generated domain list and generated outbounds
rrules = [r for r in rrules if not (r.get('domain_suffix') == ai_domains and r.get('outbound') in ('direct', 'block'))]
rrules.insert(0, {'domain_suffix': ai_domains, 'network': 'udp', 'port': 443, 'outbound': 'block'})
rrules.insert(1, {'domain_suffix': ai_domains, 'outbound': 'direct'})
route['rules'] = rrules
route.setdefault('final', 'direct')

path.write_text(json.dumps(conf, indent=2, ensure_ascii=False) + '\n')
PY

  log "Patched sing-box config: $SINGBOX_CONFIG"
}

singbox_check_and_restart() {
  local sb=""
  if command -v sing-box >/dev/null 2>&1; then
    sb="$(command -v sing-box)"
  elif [[ -x /usr/local/bin/sing-box ]]; then
    sb="/usr/local/bin/sing-box"
  else
    die "sing-box binary not found."
  fi

  local check_cmd=("$sb" check -c "$SINGBOX_CONFIG")
  if [[ -f "$SINGBOX_RELAY_CONFIG" ]]; then
    check_cmd+=( -c "$SINGBOX_RELAY_CONFIG" )
  fi

  log "Checking sing-box config..."
  ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true \
  ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM=true \
  ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true \
  "${check_cmd[@]}"

  if [[ "$NO_RESTART" -eq 0 ]]; then
    if systemctl list-unit-files sing-box.service >/dev/null 2>&1; then
      systemctl restart sing-box
      sleep 1
      systemctl is-active sing-box
      log "sing-box restarted."
    else
      warn "sing-box.service not found; config checked but service not restarted."
    fi
  fi
}

verify_singbox_client() {
  log "Testing unlock DNS from this host."
  if command -v dig >/dev/null 2>&1; then
    if [[ "$DNS_TRANSPORT" == "tcp" ]]; then
      dig +tcp +time=3 +tries=1 chatgpt.com @"$UNLOCK_IP" +short || true
      dig +tcp +time=3 +tries=1 claude.ai @"$UNLOCK_IP" +short || true
    else
      dig +time=3 +tries=1 chatgpt.com @"$UNLOCK_IP" +short || true
      dig +time=3 +tries=1 claude.ai @"$UNLOCK_IP" +short || true
    fi
  else
    warn "dig not installed; skip DNS verification."
  fi

  log "Testing TCP/443 to unlock VPS."
  timeout 5 bash -c "</dev/tcp/$UNLOCK_IP/443" && log "TCP 443 open" || warn "TCP 443 not reachable"

  log "sing-box listeners matching common ports:"
  ss -lntup | grep -E 'sing-box|:20010\b' || true
}

main() {
  parse_args "$@"
  need_root

  case "$MODE" in
    unlock-server)
      configure_dnsmasq_ai
      configure_nginx_stream
      configure_firewall_unlock
      verify_unlock_server
      ;;
    singbox-client)
      patch_singbox_client
      singbox_check_and_restart
      verify_singbox_client
      ;;
  esac

  log "Done."
}

main "$@"
