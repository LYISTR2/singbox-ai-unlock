#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
MODE=""
SINGBOX_CONFIG="/usr/local/etc/sing-box/config.json"
SINGBOX_RELAY_CONFIG="/usr/local/etc/sing-box/relay.json"
NO_RESTART=0
DRY_RUN=0
COMPAT="auto" # auto | modern (>=1.11, action: reject) | legacy (outbound: block)
# SS_URL / SS_PASSWORD can be pre-set via environment variables to keep
# secrets out of the command line and shell history.
SS_URL="${SS_URL:-}"
SS_SERVER="${SS_SERVER:-}"
SS_PORT="${SS_PORT:-}"
SS_METHOD="${SS_METHOD:-}"
SS_PASSWORD="${SS_PASSWORD:-}"
OUTBOUND_TAG="ai-unlock-ss"
OUTBOUND_DETOUR=""
DOMAINS_FILE=""
EXTRA_DOMAINS=()
BACKUP_PATH=""
BACKUP_KEEP=5
SB_BIN=""
SB_VERSION=""
TMP_CONFIG=""

# Notes on the list:
# - domain_suffix matching covers all subdomains, so only apex/parent
#   domains are needed (openai.com already covers api.openai.com etc.).
# - challenges.cloudflare.com is required so the Cloudflare challenge for
#   chatgpt.com resolves from the same exit IP as the site itself.
AI_DOMAINS=(
  # OpenAI / ChatGPT
  openai.com
  chatgpt.com
  sora.com
  oaistatic.com
  oaiusercontent.com
  # Third-party services used by ChatGPT
  featuregates.org
  statsig.com
  statsigapi.net
  intercom.io
  intercomcdn.com
  challenges.cloudflare.com
  # Anthropic / Claude
  anthropic.com
  claude.ai
  claude.com
  # Google Gemini / AI Studio
  gemini.google.com
  generativelanguage.googleapis.com
  ai.google.dev
  aistudio.google.com
  notebooklm.google.com
  # xAI / Grok
  grok.com
  x.ai
  # Others
  perplexity.ai
  poe.com
  copilot.microsoft.com
  bing.com
)

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

cleanup() {
  if [[ -n "$TMP_CONFIG" && -f "$TMP_CONFIG" ]]; then
    rm -f "$TMP_CONFIG"
  fi
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME singbox-client [options]
  $SCRIPT_NAME parse-ss --ss-url <ss://...>
  $SCRIPT_NAME rollback [--config <path>] [--no-restart]

Modes:
  singbox-client
    Patch a sing-box config so selected AI domains go through a Shadowsocks outbound.
    If parameters are omitted, the script will prompt interactively.

  parse-ss
    Decode a Shadowsocks URI and print server / port / method / password.

  rollback
    Restore the most recent backup of the sing-box config created by this
    script, then check and restart sing-box.

Options for singbox-client:
  --ss-url <ss://...>          Full Shadowsocks URI. Can also be set via env SS_URL.
  --server <host>              Shadowsocks server / hostname.
  --port <port>                Shadowsocks port.
  --method <cipher>            Shadowsocks method, for example 2022-blake3-aes-256-gcm.
  --password <password>        Shadowsocks password. Prefer env SS_PASSWORD or the
                               interactive prompt: command-line arguments can leak
                               through shell history and process lists.
  --config <path>              sing-box main config path. Default: /usr/local/etc/sing-box/config.json
  --relay-config <path>        optional second config path. Default: /usr/local/etc/sing-box/relay.json
  --tag <name>                 outbound tag to create. Default: ai-unlock-ss
  --outbound-detour <tag>      optional detour tag for the Shadowsocks outbound.
  --add-domain <d1[,d2,...]>   extra domain suffixes to route (repeatable).
  --domains-file <path>        file with extra domain suffixes, one per line
                               ('#' comments and blank lines are ignored).
  --compat <auto|modern|legacy>
                               rule syntax to generate. auto (default) detects the
                               sing-box version: >=1.11 uses "action": "reject",
                               older versions use the legacy "outbound": "block".
  --dry-run                    show a diff of the changes without writing anything.
  --no-restart                 patch and check config only, do not restart sing-box.

Examples:
  bash $SCRIPT_NAME singbox-client
  bash $SCRIPT_NAME singbox-client --ss-url 'ss://BASE64@1.2.3.4:443#JP'
  bash $SCRIPT_NAME singbox-client --ss-url 'ss://BASE64@1.2.3.4:443#JP' --dry-run
  bash $SCRIPT_NAME singbox-client --add-domain mistral.ai,meta.ai
  SS_URL='ss://BASE64@1.2.3.4:443#JP' bash $SCRIPT_NAME singbox-client
  bash $SCRIPT_NAME parse-ss --ss-url 'ss://BASE64@1.2.3.4:443#JP'
  bash $SCRIPT_NAME rollback
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
    singbox-client|parse-ss|rollback) ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage; die "Unknown mode: $MODE" ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ss-url) SS_URL="${2:-}"; shift 2 ;;
      --server) SS_SERVER="${2:-}"; shift 2 ;;
      --port) SS_PORT="${2:-}"; shift 2 ;;
      --method) SS_METHOD="${2:-}"; shift 2 ;;
      --password)
        SS_PASSWORD="${2:-}"
        warn "--password on the command line can leak via shell history and process lists; prefer env SS_PASSWORD or the interactive prompt."
        shift 2 ;;
      --config) SINGBOX_CONFIG="${2:-}"; shift 2 ;;
      --relay-config) SINGBOX_RELAY_CONFIG="${2:-}"; shift 2 ;;
      --tag) OUTBOUND_TAG="${2:-}"; shift 2 ;;
      --outbound-detour) OUTBOUND_DETOUR="${2:-}"; shift 2 ;;
      --add-domain)
        local _parts=()
        IFS=',' read -r -a _parts <<<"${2:-}"
        EXTRA_DOMAINS+=("${_parts[@]}")
        shift 2 ;;
      --domains-file) DOMAINS_FILE="${2:-}"; shift 2 ;;
      --compat)
        COMPAT="${2:-}"
        case "$COMPAT" in auto|modern|legacy) ;; *) die "--compat must be auto, modern or legacy" ;; esac
        shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --no-restart) NO_RESTART=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "Unknown argument: $1" ;;
    esac
  done

  if [[ "$MODE" == "singbox-client" && "$DRY_RUN" -eq 0 ]]; then
    interactive_fill_missing
  fi

  [[ -n "$OUTBOUND_TAG" ]] || die "--tag cannot be empty"

  case "$MODE" in
    parse-ss)
      [[ -n "$SS_URL" ]] || die "parse-ss mode requires --ss-url"
      ;;
    rollback)
      [[ -f "$SINGBOX_CONFIG" || -e "$SINGBOX_CONFIG" ]] || warn "Config $SINGBOX_CONFIG does not exist; will restore from backup anyway."
      ;;
    singbox-client)
      [[ -n "$SS_URL" || -n "$SS_SERVER" ]] || die "Provide --ss-url or --server/--port/--method/--password (or env SS_URL / SS_PASSWORD)"
      [[ -f "$SINGBOX_CONFIG" ]] || die "sing-box config not found: $SINGBOX_CONFIG"
      ;;
  esac

  if [[ -n "$DOMAINS_FILE" ]]; then
    [[ -f "$DOMAINS_FILE" ]] || die "Domains file not found: $DOMAINS_FILE"
    local _line
    while IFS= read -r _line; do
      _line="${_line%%#*}"
      _line="${_line//[[:space:]]/}"
      [[ -n "$_line" ]] && EXTRA_DOMAINS+=("$_line")
    done <"$DOMAINS_FILE"
  fi
}

find_singbox_bin() {
  if command -v sing-box >/dev/null 2>&1; then
    SB_BIN="$(command -v sing-box)"
  elif [[ -x /usr/local/bin/sing-box ]]; then
    SB_BIN="/usr/local/bin/sing-box"
  fi
}

resolve_compat() {
  [[ "$COMPAT" == "auto" ]] || { log "Rule syntax forced to: $COMPAT"; return 0; }

  if [[ -n "$SB_BIN" ]]; then
    SB_VERSION="$("$SB_BIN" version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)"
  fi

  if [[ -n "$SB_VERSION" ]]; then
    local major minor
    major="${SB_VERSION%%.*}"
    minor="$(cut -d. -f2 <<<"$SB_VERSION")"
    if (( major > 1 || (major == 1 && minor >= 11) )); then
      COMPAT="modern"
    else
      COMPAT="legacy"
    fi
    log "Detected sing-box $SB_VERSION -> using $COMPAT rule syntax."
  else
    COMPAT="modern"
    warn "Could not detect sing-box version; assuming modern (>=1.11) rule syntax. Use --compat legacy to override."
  fi
}

backup_file() {
  local f="$1"
  if [[ -e "$f" ]]; then
    local stamp bak
    stamp="$(date -u +%Y%m%d-%H%M%S)"
    bak="${f}.bak.${stamp}"
    cp -a "$f" "$bak"
    chmod 600 "$bak" 2>/dev/null || true
    BACKUP_PATH="$bak"
    log "Backed up $f -> $bak"
    prune_backups "$f"
  fi
}

prune_backups() {
  local f="$1" old
  # Timestamped names sort chronologically; keep the newest $BACKUP_KEEP.
  while IFS= read -r old; do
    [[ -n "$old" ]] || continue
    rm -f -- "$old"
    log "Pruned old backup: $old"
  done < <(ls -1 "${f}".bak.* 2>/dev/null | sort | head -n -"$BACKUP_KEEP" || true)
}

latest_backup() {
  local f="$1"
  ls -1 "${f}".bak.* 2>/dev/null | sort | tail -n 1 || true
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
from_base64 = False
if '@' not in raw:
    decoded = base64.urlsafe_b64decode(raw + '=' * (-len(raw) % 4)).decode()
    if '@' not in decoded:
        raise SystemExit('Unsupported ss:// format')
    raw = decoded
    from_base64 = True
userinfo, hostport = raw.rsplit('@', 1)
if ':' not in userinfo:
    userinfo = base64.urlsafe_b64decode(userinfo + '=' * (-len(userinfo) % 4)).decode()
    from_base64 = True
if ':' not in userinfo:
    raise SystemExit('Invalid method:password segment')
method, password = userinfo.split(':', 1)
if not from_base64:
    # SIP002 plain userinfo is percent-encoded; base64-decoded passwords are raw.
    password = urllib.parse.unquote(password)
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

  local target="$SINGBOX_CONFIG"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    TMP_CONFIG="$(mktemp /tmp/singbox-ai-unlock.XXXXXX.json)"
    cp "$SINGBOX_CONFIG" "$TMP_CONFIG"
    target="$TMP_CONFIG"
  else
    backup_file "$SINGBOX_CONFIG"
  fi

  local extra_domains_str=""
  if [[ ${#EXTRA_DOMAINS[@]} -gt 0 ]]; then
    extra_domains_str="$(printf '%s\n' "${EXTRA_DOMAINS[@]}")"
  fi

  AI_DOMAINS_STR="$(printf '%s\n' "${AI_DOMAINS[@]}")" \
  EXTRA_DOMAINS_STR="$extra_domains_str" \
  SINGBOX_CONFIG="$target" \
  SS_SERVER="$SS_SERVER" \
  SS_PORT="$SS_PORT" \
  SS_METHOD="$SS_METHOD" \
  SS_PASSWORD="$SS_PASSWORD" \
  OUTBOUND_TAG="$OUTBOUND_TAG" \
  OUTBOUND_DETOUR="$OUTBOUND_DETOUR" \
  COMPAT="$COMPAT" \
  python3 - <<'PY'
import json
import os
import pathlib
import sys

path = pathlib.Path(os.environ['SINGBOX_CONFIG'])
try:
    conf = json.loads(path.read_text())
except json.JSONDecodeError as exc:
    raise SystemExit(f'Config is not valid JSON ({path}): {exc}')

modern = os.environ.get('COMPAT', 'modern') == 'modern'
outbound_tag = os.environ['OUTBOUND_TAG']
outbound_detour = os.environ.get('OUTBOUND_DETOUR', '')

def read_domains(env_name):
    return [x.strip() for x in os.environ.get(env_name, '').splitlines() if x.strip()]

def dedupe_suffixes(domains):
    """Drop entries already covered by a parent suffix in the list."""
    ds = set(domains)
    out = []
    for d in sorted(ds):
        if any(d != other and d.endswith('.' + other) for other in ds):
            continue
        out.append(d)
    return out

ai_domains = dedupe_suffixes(read_domains('AI_DOMAINS_STR') + read_domains('EXTRA_DOMAINS_STR'))

# Clean up the old DNS hijack scheme if present.
dns = conf.setdefault('dns', {})
servers = dns.setdefault('servers', [])
dns['servers'] = [server for server in servers if server.get('tag') != 'ai-unlock-dns']
rules = dns.setdefault('rules', [])
dns['rules'] = [rule for rule in rules if rule.get('server') != 'ai-unlock-dns']

outbounds = conf.setdefault('outbounds', [])
outbounds = [outbound for outbound in outbounds if outbound.get('tag') != outbound_tag]
# Also drop a leftover outbound created under the default tag by a previous
# run, so changing --tag does not leave a dangling shadowsocks outbound.
if outbound_tag != 'ai-unlock-ss':
    outbounds = [
        outbound for outbound in outbounds
        if not (outbound.get('tag') == 'ai-unlock-ss' and outbound.get('type') == 'shadowsocks')
    ]
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
if not modern and not any(outbound.get('tag') == 'block' for outbound in outbounds):
    # The block outbound is deprecated since sing-box 1.11 (use "action": "reject").
    outbounds.append({'type': 'block', 'tag': 'block'})
conf['outbounds'] = outbounds

route = conf.setdefault('route', {})
route_rules = route.setdefault('rules', [])

markers = {'openai.com', 'chatgpt.com', 'claude.ai'}
def is_generated(rule):
    """Detect rules previously generated by this script (any version)."""
    domain_suffix = rule.get('domain_suffix')
    if not isinstance(domain_suffix, list):
        return False
    # A rule listing 2+ of our marker domains is one of ours, whatever tag
    # or syntax it was generated with -- this also cleans up rules left
    # behind after a --tag change.
    return len(markers & set(domain_suffix)) >= 2

route_rules = [rule for rule in route_rules if not is_generated(rule)]

# Insert after any leading action rules (sniff / hijack-dns / resolve):
# since sing-box 1.11 those must run before route rules, and domain-based
# routing itself depends on sniff having run.
insert_at = 0
while insert_at < len(route_rules) and route_rules[insert_at].get('action') in ('sniff', 'hijack-dns', 'resolve'):
    insert_at += 1

if modern:
    udp_block_rule = {'domain_suffix': ai_domains, 'network': 'udp', 'port': 443, 'action': 'reject'}
else:
    udp_block_rule = {'domain_suffix': ai_domains, 'network': 'udp', 'port': 443, 'outbound': 'block'}
ai_route_rule = {'domain_suffix': ai_domains, 'outbound': outbound_tag}

route_rules.insert(insert_at, udp_block_rule)
route_rules.insert(insert_at + 1, ai_route_rule)
route['rules'] = route_rules
if route.get('final') is None:
    route['final'] = 'direct'

path.write_text(json.dumps(conf, indent=2, ensure_ascii=False) + '\n')
print(f'AI domain suffixes in routing rule: {len(ai_domains)}', file=sys.stderr)
PY

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry run: showing diff, original config NOT modified."
    diff -u "$SINGBOX_CONFIG" "$TMP_CONFIG" || true
  else
    chmod 600 "$SINGBOX_CONFIG" 2>/dev/null || true
    log "Patched sing-box config: $SINGBOX_CONFIG"
  fi
}

svc_exists() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl list-unit-files --no-legend "$1.service" 2>/dev/null | grep -q "$1" && return 0
  # Fallback for systemd versions where list-unit-files patterns behave differently.
  systemctl cat "$1" >/dev/null 2>&1
}

restore_backup_after_failure() {
  if [[ -n "$BACKUP_PATH" && -f "$BACKUP_PATH" ]]; then
    cp -a "$BACKUP_PATH" "$SINGBOX_CONFIG"
    warn "Config check failed; restored previous config from $BACKUP_PATH"
  fi
}

singbox_check_and_restart() {
  local check_target="${1:-$SINGBOX_CONFIG}"

  if [[ -z "$SB_BIN" ]]; then
    if [[ "$NO_RESTART" -eq 1 || "$DRY_RUN" -eq 1 ]]; then
      warn "sing-box binary not found; skipped config check."
      return 0
    fi
    restore_backup_after_failure
    die "sing-box binary not found."
  fi

  local check_cmd=("$SB_BIN" check -c "$check_target")
  if [[ -f "$SINGBOX_RELAY_CONFIG" ]]; then
    check_cmd+=( -c "$SINGBOX_RELAY_CONFIG" )
  fi

  log "Checking sing-box config..."
  if ! ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true \
       ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM=true \
       ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true \
       "${check_cmd[@]}"; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      die "sing-box config check failed on the dry-run result (original config untouched)."
    fi
    restore_backup_after_failure
    die "sing-box config check failed. Original config restored, nothing was broken."
  fi
  log "Config check passed."

  if [[ "$NO_RESTART" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
    if svc_exists sing-box; then
      systemctl restart sing-box
      sleep 1
      if systemctl is-active --quiet sing-box; then
        log "sing-box restarted and active."
      else
        err "sing-box failed to start after restart."
        err "Inspect logs with: journalctl -u sing-box -n 50 --no-pager"
        [[ -n "$BACKUP_PATH" ]] && warn "Roll back with: $SCRIPT_NAME rollback --config $SINGBOX_CONFIG"
        exit 1
      fi
    else
      warn "sing-box service not found; config checked but service not restarted."
    fi
  fi
}

verify_singbox_client() {
  log "Testing TCP to Shadowsocks server."
  if timeout 6 bash -c "</dev/tcp/$SS_SERVER/$SS_PORT" 2>/dev/null; then
    log "TCP $SS_PORT open on $SS_SERVER"
  else
    warn "Cannot reach $SS_SERVER:$SS_PORT"
  fi

  if command -v ss >/dev/null 2>&1; then
    log "Current sing-box listeners:"
    ss -lntup 2>/dev/null | grep -E 'sing-box' || true
  fi

  log "AI domains routed to outbound tag: $OUTBOUND_TAG"
}

do_rollback() {
  need_root
  local latest
  latest="$(latest_backup "$SINGBOX_CONFIG")"
  [[ -n "$latest" ]] || die "No backup found matching ${SINGBOX_CONFIG}.bak.*"
  cp -a "$latest" "$SINGBOX_CONFIG"
  chmod 600 "$SINGBOX_CONFIG" 2>/dev/null || true
  log "Restored $SINGBOX_CONFIG from $latest"
  BACKUP_PATH=""
  find_singbox_bin
  singbox_check_and_restart
  log "Rollback done."
}

main() {
  parse_args "$@"

  case "$MODE" in
    parse-ss)
      show_parsed_ss
      exit 0
      ;;
    rollback)
      do_rollback
      exit 0
      ;;
  esac

  if [[ "$DRY_RUN" -eq 0 ]]; then
    need_root
  fi
  find_singbox_bin
  resolve_compat
  parse_ss_url
  validate_ss_fields
  patch_singbox_client

  if [[ "$DRY_RUN" -eq 1 ]]; then
    singbox_check_and_restart "$TMP_CONFIG"
    log "Dry run finished. Re-run without --dry-run to apply."
    exit 0
  fi

  singbox_check_and_restart
  verify_singbox_client
  log "Done."
}

main "$@"
