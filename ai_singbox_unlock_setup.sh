#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
MODE=""
SINGBOX_CONFIG="/usr/local/etc/sing-box/config.json"
SINGBOX_RELAY_CONFIG="/usr/local/etc/sing-box/relay.json"
NO_RESTART=0
SS_URL=""
SS_SERVER=""
SS_PORT=""
SS_METHOD=""
SS_PASSWORD=""
OUTBOUND_TAG="ai-unlock-ss"
OUTBOUND_DETOUR=""

AI_DOMAINS=(
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
)

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME singbox-client [options]
  $SCRIPT_NAME parse-ss --ss-url <ss://...>

Modes:
  singbox-client
    Patch a sing-box config so selected AI domains go through a Shadowsocks outbound.
    If parameters are omitted, the script will prompt interactively.

  parse-ss
    Decode a Shadowsocks URI and print server / port / method / password.

Options for singbox-client:
  --ss-url <ss://...>          Full Shadowsocks URI.
  --server <host>              Shadowsocks server / hostname.
  --port <port>                Shadowsocks port.
  --method <cipher>            Shadowsocks method, for example 2022-blake3-aes-256-gcm.
  --password <password>        Shadowsocks password.
  --config <path>              sing-box main config path. Default: /usr/local/etc/sing-box/config.json
  --relay-config <path>        optional second config path. Default: /usr/local/etc/sing-box/relay.json
  --tag <name>                 outbound tag to create. Default: ai-unlock-ss
  --outbound-detour <tag>      optional detour tag for the Shadowsocks outbound.
  --no-restart                 patch and check config only, do not restart sing-box.

Examples:
  bash $SCRIPT_NAME singbox-client
  bash $SCRIPT_NAME singbox-client --ss-url 'ss://BASE64@1.2.3.4:443#JP'
  bash $SCRIPT_NAME singbox-client --server example.com --port 443 --method 2022-blake3-aes-256-gcm --password 'YOUR_PASSWORD'
  bash $SCRIPT_NAME parse-ss --ss-url 'ss://BASE64@1.2.3.4:443#JP'
EOF
}

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Please run as root."
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

prompt_value() {
  local var_name="$1"
  local prompt="$2"
  local default="${3:-}"
  local secret="${4:-0}"
  local value=""
  while true; do
    if [[ -n "$default" ]]; then
      if [[ "$secret" == "1" ]]; then
        read -r -s -p "$prompt [$default]: " value
        echo
      else
        read -r -p "$prompt [$default]: " value
      fi
      value="${value:-$default}"
    else
      if [[ "$secret" == "1" ]]; then
        read -r -s -p "$prompt: " value
        echo
      else
        read -r -p "$prompt: " value
      fi
    fi
    [[ -n "$value" ]] && break
  done
  printf -v "$var_name" '%s' "$value"
}

prompt_optional() {
  local var_name="$1"
  local prompt="$2"
  local default="${3:-}"
  local value=""
  read -r -p "$prompt${default:+ [$default]}: " value
  value="${value:-$default}"
  printf -v "$var_name" '%s' "$value"
}

interactive_fill_missing() {
  [[ -t 0 ]] || return 0

  if [[ "$MODE" == "singbox-client" ]]; then
    local answer=""
    prompt_optional answer "sing-box config path" "$SINGBOX_CONFIG"
    SINGBOX_CONFIG="$answer"

    prompt_optional answer "optional relay config path; leave default if present" "$SINGBOX_RELAY_CONFIG"
    SINGBOX_RELAY_CONFIG="$answer"

    prompt_optional answer "AI outbound tag" "$OUTBOUND_TAG"
    OUTBOUND_TAG="$answer"

    prompt_optional answer "optional outbound detour tag; leave empty for none" "$OUTBOUND_DETOUR"
    OUTBOUND_DETOUR="$answer"

    if [[ -z "$SS_URL" && -z "$SS_SERVER" ]]; then
      prompt_optional answer "Paste full ss:// node; leave empty to input manually" ""
      SS_URL="$answer"
    fi

    if [[ -z "$SS_URL" && -z "$SS_SERVER" ]]; then
      prompt_value SS_SERVER "Shadowsocks server / hostname"
      while true; do
        prompt_value SS_PORT "Shadowsocks port"
        valid_port "$SS_PORT" && break
        warn "Invalid port: $SS_PORT"
      done
      prompt_value SS_METHOD "Shadowsocks method (example: 2022-blake3-aes-256-gcm)"
      prompt_value SS_PASSWORD "Shadowsocks password" "" 1
    fi
  fi
}

parse_args() {
  [[ $# -gt 0 ]] || { usage; exit 1; }
  MODE="$1"
  shift

  case "$MODE" in
    singbox-client|parse-ss) ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage; die "Unknown mode: $MODE" ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ss-url) SS_URL="${2:-}"; shift 2 ;;
      --server) SS_SERVER="${2:-}"; shift 2 ;;
      --port) SS_PORT="${2:-}"; shift 2 ;;
      --method) SS_METHOD="${2:-}"; shift 2 ;;
      --password) SS_PASSWORD="${2:-}"; shift 2 ;;
      --config) SINGBOX_CONFIG="${2:-}"; shift 2 ;;
      --relay-config) SINGBOX_RELAY_CONFIG="${2:-}"; shift 2 ;;
      --tag) OUTBOUND_TAG="${2:-}"; shift 2 ;;
      --outbound-detour) OUTBOUND_DETOUR="${2:-}"; shift 2 ;;
      --no-restart) NO_RESTART=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "Unknown argument: $1" ;;
    esac
  done

  interactive_fill_missing

  [[ -n "$OUTBOUND_TAG" ]] || die "--tag cannot be empty"

  if [[ "$MODE" == "parse-ss" ]]; then
    [[ -n "$SS_URL" ]] || die "parse-ss mode requires --ss-url"
  else
    [[ -n "$SS_URL" || -n "$SS_SERVER" ]] || die "Provide --ss-url or --server/--port/--method/--password"
    [[ -f "$SINGBOX_CONFIG" ]] || die "sing-box config not found: $SINGBOX_CONFIG"
  fi
}

backup_file() {
  local f="$1"
  if [[ -e "$f" ]]; then
    local bak="${f}.bak.$(date -u +%Y%m%d-%H%M%S)"
    cp -a "$f" "$bak"
    log "Backed up $f -> $bak"
  fi
}

parse_ss_url() {
  [[ -n "$SS_URL" ]] || return 0
  local parsed
  parsed="$(SS_URL="$SS_URL" python3 - <<'PY'
import os
import base64
import urllib.parse

url = os.environ['SS_URL'].strip()
if not url.startswith('ss://'):
    raise SystemExit('Shadowsocks URL must start with ss://')
raw = url[5:]
raw = raw.split('#', 1)[0]
if '?' in raw:
    raw, query = raw.split('?', 1)
    params = urllib.parse.parse_qs(query)
    plugin = params.get('plugin', [''])[0]
    if plugin:
        raise SystemExit('Plugin parameters are not supported by this script')
if '@' not in raw:
    decoded = base64.urlsafe_b64decode(raw + '=' * (-len(raw) % 4)).decode()
    if '@' not in decoded:
        raise SystemExit('Unsupported ss:// format')
    raw = decoded
userinfo, hostport = raw.rsplit('@', 1)
if ':' not in userinfo:
    userinfo = base64.urlsafe_b64decode(userinfo + '=' * (-len(userinfo) % 4)).decode()
if ':' not in userinfo:
    raise SystemExit('Invalid method:password segment')
method, password = userinfo.split(':', 1)
if hostport.startswith('['):
    host, rest = hostport[1:].split(']', 1)
    if not rest.startswith(':'):
        raise SystemExit('Invalid IPv6 host/port in ss:// URL')
    port = rest[1:]
else:
    if ':' not in hostport:
        raise SystemExit('Missing port in ss:// URL')
    host, port = hostport.rsplit(':', 1)
print(method)
print(password)
print(host)
print(port)
PY
)"
  SS_METHOD="$(printf '%s\n' "$parsed" | sed -n '1p')"
  SS_PASSWORD="$(printf '%s\n' "$parsed" | sed -n '2p')"
  SS_SERVER="$(printf '%s\n' "$parsed" | sed -n '3p')"
  SS_PORT="$(printf '%s\n' "$parsed" | sed -n '4p')"
}

validate_ss_fields() {
  [[ -n "$SS_SERVER" ]] || die "Shadowsocks server is empty"
  [[ -n "$SS_METHOD" ]] || die "Shadowsocks method is empty"
  [[ -n "$SS_PASSWORD" ]] || die "Shadowsocks password is empty"
  valid_port "$SS_PORT" || die "Invalid Shadowsocks port: $SS_PORT"
}

show_parsed_ss() {
  parse_ss_url
  validate_ss_fields
  cat <<EOF
server=$SS_SERVER
port=$SS_PORT
method=$SS_METHOD
password=$SS_PASSWORD
EOF
}

patch_singbox_client() {
  need_cmd python3
  backup_file "$SINGBOX_CONFIG"

  AI_DOMAINS_STR="$(printf '%s\n' "${AI_DOMAINS[@]}")" \
  SINGBOX_CONFIG="$SINGBOX_CONFIG" \
  SS_SERVER="$SS_SERVER" \
  SS_PORT="$SS_PORT" \
  SS_METHOD="$SS_METHOD" \
  SS_PASSWORD="$SS_PASSWORD" \
  OUTBOUND_TAG="$OUTBOUND_TAG" \
  OUTBOUND_DETOUR="$OUTBOUND_DETOUR" \
  python3 - <<'PY'
import json
import os
import pathlib

path = pathlib.Path(os.environ['SINGBOX_CONFIG'])
conf = json.loads(path.read_text())
ai_domains = [x.strip() for x in os.environ['AI_DOMAINS_STR'].splitlines() if x.strip()]
outbound_tag = os.environ['OUTBOUND_TAG']
outbound_detour = os.environ.get('OUTBOUND_DETOUR', '')

# Clean up the old DNS hijack scheme if present.
dns = conf.setdefault('dns', {})
servers = dns.setdefault('servers', [])
dns['servers'] = [server for server in servers if server.get('tag') != 'ai-unlock-dns']
rules = dns.setdefault('rules', [])
dns['rules'] = [rule for rule in rules if rule.get('server') != 'ai-unlock-dns']

outbounds = conf.setdefault('outbounds', [])
outbounds = [outbound for outbound in outbounds if outbound.get('tag') != outbound_tag]
ss_outbound = {
    'type': 'shadowsocks',
    'tag': outbound_tag,
    'server': os.environ['SS_SERVER'],
    'server_port': int(os.environ['SS_PORT']),
    'method': os.environ['SS_METHOD'],
    'password': os.environ['SS_PASSWORD'],
}
if outbound_detour:
    ss_outbound['detour'] = outbound_detour
outbounds.append(ss_outbound)
if not any(outbound.get('tag') == 'direct' for outbound in outbounds):
    outbounds.insert(0, {'type': 'direct', 'tag': 'direct'})
if not any(outbound.get('tag') == 'block' for outbound in outbounds):
    outbounds.append({'type': 'block', 'tag': 'block'})
conf['outbounds'] = outbounds

route = conf.setdefault('route', {})
route_rules = route.setdefault('rules', [])
markers = {'openai.com', 'chatgpt.com', 'claude.ai'}
def is_old_generated(rule):
    domain_suffix = rule.get('domain_suffix')
    if not isinstance(domain_suffix, list):
        return False
    if not markers.issubset(set(domain_suffix)):
        return False
    return rule.get('outbound') in ('direct', 'block', outbound_tag, 'ai-unlock-ss') or rule.get('server') == 'ai-unlock-dns'
route_rules = [rule for rule in route_rules if not is_old_generated(rule)]
route_rules.insert(0, {'domain_suffix': ai_domains, 'network': 'udp', 'port': 443, 'outbound': 'block'})
route_rules.insert(1, {'domain_suffix': ai_domains, 'outbound': outbound_tag})
route['rules'] = route_rules
if route.get('final') is None:
    route['final'] = 'direct'

path.write_text(json.dumps(conf, indent=2, ensure_ascii=False) + '\n')
PY

  log "Patched sing-box config: $SINGBOX_CONFIG"
}

svc_exists() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl list-unit-files "$1.service" >/dev/null 2>&1
  else
    return 1
  fi
}

singbox_check_and_restart() {
  local sb=""
  if command -v sing-box >/dev/null 2>&1; then
    sb="$(command -v sing-box)"
  elif [[ -x /usr/local/bin/sing-box ]]; then
    sb="/usr/local/bin/sing-box"
  else
    if [[ "$NO_RESTART" -eq 1 ]]; then
      warn "sing-box binary not found; skipped config check because --no-restart is set."
      return 0
    fi
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
    if svc_exists sing-box; then
      systemctl restart sing-box
      sleep 1
      systemctl is-active sing-box
      log "sing-box restarted."
    else
      warn "sing-box service not found; config checked but service not restarted."
    fi
  fi
}

verify_singbox_client() {
  log "Testing TCP to Shadowsocks server."
  timeout 6 bash -c "</dev/tcp/$SS_SERVER/$SS_PORT" && log "TCP $SS_PORT open on $SS_SERVER" || warn "Cannot reach $SS_SERVER:$SS_PORT"

  log "Current sing-box listeners:"
  ss -lntup | grep -E 'sing-box' || true

  log "AI domains routed to outbound tag: $OUTBOUND_TAG"
}

main() {
  parse_args "$@"

  if [[ "$MODE" == "parse-ss" ]]; then
    show_parsed_ss
    exit 0
  fi

  need_root
  parse_ss_url
  validate_ss_fields
  patch_singbox_client
  singbox_check_and_restart
  verify_singbox_client
  log "Done."
}

main "$@"
