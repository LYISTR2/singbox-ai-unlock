#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
OUTBOUND_TAG="ai-unlock-ss"
SERVICE=""
SB_BIN=""
SB_VERSION=""
CONFIG=""
CONFIG_SOURCE=""
SS_URL="${SS_URL:-}"
SS_SERVER="${SS_SERVER:-}"
SS_PORT="${SS_PORT:-}"
SS_METHOD="${SS_METHOD:-}"
SS_PASSWORD="${SS_PASSWORD:-}"
NO_RESTART=0
DRY_RUN=0
BACKUP_KEEP=5
TMP_DIR=""
CANDIDATE=""
CHECK_CONFIGS=()
EXTRA_DOMAINS=()

AI_DOMAINS=(
  openai.com chatgpt.com sora.com oaistatic.com oaiusercontent.com
  featuregates.org statsig.com statsigapi.net intercom.io intercomcdn.com
  challenges.cloudflare.com
  anthropic.com claude.ai claude.com
  gemini.google.com generativelanguage.googleapis.com ai.google.dev
  aistudio.google.com notebooklm.google.com
  grok.com x.ai perplexity.ai poe.com copilot.microsoft.com bing.com
)

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
cleanup() { [[ -z "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME [options]

Required:
  --ss-url <ss://...>       Shadowsocks URL. Safer: SS_URL='ss://...' $SCRIPT_NAME

Options:
  --config <path>           sing-box JSON config to patch (normally auto-detected)
  --service <unit>          systemd unit to restart (normally auto-detected)
  --add-domain <a,b,...>    extra domain suffixes routed through SS (repeatable)
  --dry-run                 print the JSON diff; do not write or restart
  --no-restart              write and validate config, but do not restart
  -h, --help                show this help

Interactive use:
  Run without --ss-url in a terminal and paste the SS URL when prompted.
EOF
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root."; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ss-url) [[ $# -ge 2 ]] || die "--ss-url requires a value"; SS_URL="$2"; shift 2 ;;
      --config) [[ $# -ge 2 ]] || die "--config requires a value"; CONFIG="$2"; CONFIG_SOURCE="argument"; shift 2 ;;
      --service) [[ $# -ge 2 ]] || die "--service requires a value"; SERVICE="${2%.service}"; shift 2 ;;
      --add-domain)
        [[ $# -ge 2 ]] || die "--add-domain requires a value"
        local parts=()
        IFS=',' read -r -a parts <<<"$2"
        EXTRA_DOMAINS+=("${parts[@]}")
        shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --no-restart) NO_RESTART=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "Unknown option: $1" ;;
    esac
  done
}

find_singbox() {
  if command -v sing-box >/dev/null 2>&1; then
    SB_BIN="$(command -v sing-box)"
  else
    local path
    for path in /usr/local/bin/sing-box /usr/bin/sing-box /opt/sing-box/sing-box; do
      [[ -x "$path" ]] && { SB_BIN="$path"; break; }
    done
  fi
  [[ -n "$SB_BIN" ]] || die "sing-box binary not found. Install sing-box first."
  SB_BIN="$(readlink -f "$SB_BIN" 2>/dev/null || printf '%s' "$SB_BIN")"
  SB_VERSION="$("$SB_BIN" version 2>/dev/null | head -n 1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true)"
  log "Found sing-box: $SB_BIN${SB_VERSION:+ ($SB_VERSION)}"
}

unit_exists() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl cat "$1.service" >/dev/null 2>&1
}

detect_service() {
  [[ -n "$SERVICE" ]] && { unit_exists "$SERVICE" || die "systemd unit not found: $SERVICE.service"; return; }
  local unit
  for unit in sing-box singbox; do
    unit_exists "$unit" && { SERVICE="$unit"; break; }
  done
  if [[ -z "$SERVICE" ]] && command -v systemctl >/dev/null 2>&1; then
    unit="$(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '$1 ~ /^sing-box@.*\.service$/ {sub(/\.service$/, "", $1); print $1; exit}')"
    [[ -n "$unit" ]] && SERVICE="$unit"
  fi
  if [[ -n "$SERVICE" ]]; then
    log "Found service: $SERVICE.service"
  else
    warn "No sing-box systemd service detected; config can still be patched."
  fi
}

extract_config_args() {
  python3 - "$@" <<'PY'
import pathlib, shlex, sys
args = sys.argv[1:]
out = []
i = 0
while i < len(args):
    arg = args[i]
    if arg in ('-c', '--config') and i + 1 < len(args):
        out.append(args[i + 1]); i += 2; continue
    if arg.startswith('--config='):
        out.append(arg.split('=', 1)[1]); i += 1; continue
    if arg in ('-C', '--config-directory') and i + 1 < len(args):
        directory = pathlib.Path(args[i + 1])
        if directory.is_dir(): out.extend(str(p) for p in sorted(directory.glob('*.json')))
        i += 2; continue
    if arg.startswith('--config-directory='):
        directory = pathlib.Path(arg.split('=', 1)[1])
        if directory.is_dir(): out.extend(str(p) for p in sorted(directory.glob('*.json')))
    i += 1
for item in out:
    print(item)
PY
}

service_exec_words() {
  [[ -n "$SERVICE" ]] || return 0
  local line
  line="$(systemctl show "$SERVICE.service" -p ExecStart --value 2>/dev/null || true)"
  [[ -n "$line" ]] || return 0
  EXEC_LINE="$line" python3 - <<'PY'
import os, re
s = os.environ['EXEC_LINE']
# systemctl show commonly renders ExecStart as:
# { path = /bin/sing-box ; argv[] = { /bin/sing-box run -c /x.json } ; ... }
m = re.search(r'argv\[\]\s*=\s*\{(.*?)\}\s*;', s)
if m:
    s = m.group(1)
    words = [w.strip('"') for w in re.split(r'[\s,;]+', s.strip()) if w]
else:
    # Other systemd versions print a command-like representation.
    import shlex
    try: words = shlex.split(s)
    except ValueError: words = s.split()
for word in words:
    print(word)
PY
}

add_check_config() {
  local file="$1" item
  [[ -f "$file" ]] || return 0
  file="$(readlink -f "$file" 2>/dev/null || printf '%s' "$file")"
  for item in "${CHECK_CONFIGS[@]}"; do [[ "$item" == "$file" ]] && return 0; done
  CHECK_CONFIGS+=("$file")
}

detect_configs() {
  local words=() file candidate
  if [[ -n "$SERVICE" ]]; then
    mapfile -t words < <(service_exec_words)
    if [[ ${#words[@]} -gt 0 ]]; then
      while IFS= read -r file; do add_check_config "$file"; done < <(extract_config_args "${words[@]}")
    fi
  fi

  if [[ -n "$CONFIG" ]]; then
    [[ -f "$CONFIG" ]] || die "Config not found: $CONFIG"
    CONFIG="$(readlink -f "$CONFIG" 2>/dev/null || printf '%s' "$CONFIG")"
    add_check_config "$CONFIG"
  else
    # Prefer a config discovered from the active service that actually owns outbounds/route.
    for file in "${CHECK_CONFIGS[@]}"; do
      if python3 - "$file" <<'PY' >/dev/null 2>&1
import json, sys
c=json.load(open(sys.argv[1]))
raise SystemExit(0 if isinstance(c,dict) and ('outbounds' in c or 'route' in c) else 1)
PY
      then CONFIG="$file"; CONFIG_SOURCE="service"; break; fi
    done
    if [[ -z "$CONFIG" ]]; then
      for candidate in \
        /usr/local/etc/sing-box/config.json /etc/sing-box/config.json \
        /etc/singbox/config.json /opt/sing-box/config.json; do
        [[ -f "$candidate" ]] && { CONFIG="$(readlink -f "$candidate")"; CONFIG_SOURCE="common path"; add_check_config "$CONFIG"; break; }
      done
    fi
  fi

  [[ -n "$CONFIG" ]] || die "Could not auto-detect the sing-box JSON config. Use --config /path/config.json."
  [[ -r "$CONFIG" ]] || die "Config is not readable: $CONFIG"
  log "Config to patch: $CONFIG ($CONFIG_SOURCE)"
  if [[ ${#CHECK_CONFIGS[@]} -gt 1 ]]; then
    log "Config check will include ${#CHECK_CONFIGS[@]} files from the service command."
  fi
}

prompt_ss_url() {
  [[ -n "$SS_URL" || -n "$SS_SERVER" ]] && return 0
  [[ -t 0 ]] || die "Set SS_URL or use --ss-url."
  read -r -s -p "Paste Shadowsocks ss:// URL: " SS_URL
  printf '\n'
  [[ -n "$SS_URL" ]] || die "SS URL cannot be empty."
}

parse_ss_url() {
  [[ -n "$SS_URL" ]] || return 0
  local parsed
  parsed="$(SS_URL="$SS_URL" python3 - <<'PY'
import base64, json, os, urllib.parse
url=os.environ['SS_URL'].strip()
if not url.startswith('ss://'): raise SystemExit('Shadowsocks URL must start with ss://')
raw=url[5:].split('#',1)[0]
if '?' in raw:
    raw,query=raw.split('?',1)
    if urllib.parse.parse_qs(query).get('plugin',[''])[0]:
        raise SystemExit('SIP003 plugin parameters are not supported')
encoded=False
if '@' not in raw:
    try: raw=base64.urlsafe_b64decode(raw+'='*(-len(raw)%4)).decode(); encoded=True
    except Exception as e: raise SystemExit(f'Invalid base64 ss:// URL: {e}')
if '@' not in raw: raise SystemExit('Unsupported ss:// format')
userinfo,hostport=raw.rsplit('@',1)
if ':' not in userinfo:
    try: userinfo=base64.urlsafe_b64decode(userinfo+'='*(-len(userinfo)%4)).decode(); encoded=True
    except Exception as e: raise SystemExit(f'Invalid base64 userinfo: {e}')
if ':' not in userinfo: raise SystemExit('Invalid method:password segment')
method,password=userinfo.split(':',1)
if not encoded: password=urllib.parse.unquote(password)
if '\n' in password or '\r' in password or '\0' in password:
    raise SystemExit('Password contains unsupported control characters')
if hostport.startswith('['):
    try: host,rest=hostport[1:].split(']',1)
    except ValueError: raise SystemExit('Invalid IPv6 host')
    if not rest.startswith(':'): raise SystemExit('Missing IPv6 port')
    port=rest[1:]
else:
    if ':' not in hostport: raise SystemExit('Missing port')
    host,port=hostport.rsplit(':',1)
print(json.dumps({'method':method,'password':password,'server':host,'port':port}))
PY
)" || die "Failed to parse SS URL."
  local fields=()
  mapfile -t fields < <(PARSED="$parsed" python3 - <<'PY'
import json, os
p=json.loads(os.environ['PARSED'])
for key in ('method','password','server','port'):
    print(str(p[key]))
PY
)
  [[ ${#fields[@]} -eq 4 ]] || die "Failed to decode parsed SS fields."
  SS_METHOD="${fields[0]}"
  SS_PASSWORD="${fields[1]}"
  SS_SERVER="${fields[2]}"
  SS_PORT="${fields[3]}"
}

validate_ss() {
  [[ -n "$SS_SERVER" && -n "$SS_METHOD" && -n "$SS_PASSWORD" ]] || die "Incomplete Shadowsocks node."
  [[ "$SS_PORT" =~ ^[0-9]+$ ]] || die "Invalid Shadowsocks port: $SS_PORT"
  local port=$((10#$SS_PORT))
  (( port >= 1 && port <= 65535 )) || die "Invalid Shadowsocks port: $SS_PORT"
  SS_PORT="$port"
}

version_is_modern() {
  [[ -z "$SB_VERSION" ]] && return 0
  local major minor rest
  IFS=. read -r major minor rest <<<"$SB_VERSION"
  (( major > 1 || (major == 1 && minor >= 11) ))
}

make_candidate() {
  TMP_DIR="$(mktemp -d /tmp/singbox-ai-unlock.XXXXXX)"
  CANDIDATE="$TMP_DIR/config.json"
  cp -a -- "$CONFIG" "$CANDIDATE"

  local domains extra=""
  domains="$(printf '%s\n' "${AI_DOMAINS[@]}")"
  [[ ${#EXTRA_DOMAINS[@]} -eq 0 ]] || extra="$(printf '%s\n' "${EXTRA_DOMAINS[@]}")"

  CONFIG_PATH="$CANDIDATE" AI_DOMAINS_STR="$domains" EXTRA_DOMAINS_STR="$extra" \
  SS_SERVER="$SS_SERVER" SS_PORT="$SS_PORT" SS_METHOD="$SS_METHOD" SS_PASSWORD="$SS_PASSWORD" \
  MODERN="$(version_is_modern && printf 1 || printf 0)" python3 - <<'PY'
import json, os, pathlib
path=pathlib.Path(os.environ['CONFIG_PATH'])
try: conf=json.loads(path.read_text())
except json.JSONDecodeError as e: raise SystemExit(f'Invalid sing-box JSON: {e}')
if not isinstance(conf,dict): raise SystemExit('sing-box config root must be an object')
modern=os.environ['MODERN']=='1'
tag='ai-unlock-ss'

def domains(name):
    values=[]
    for value in os.environ.get(name,'').splitlines():
        value=value.strip().lower().strip('.')
        if value and all(c.isalnum() or c in '.-' for c in value): values.append(value)
        elif value: raise SystemExit(f'Invalid domain suffix: {value}')
    return values

def dedupe(values):
    values=set(values)
    return [d for d in sorted(values) if not any(d!=p and d.endswith('.'+p) for p in values)]

wanted=dedupe(domains('AI_DOMAINS_STR')+domains('EXTRA_DOMAINS_STR'))
ss={'type':'shadowsocks','tag':tag,'server':os.environ['SS_SERVER'],
    'server_port':int(os.environ['SS_PORT']),'method':os.environ['SS_METHOD'],
    'password':os.environ['SS_PASSWORD']}
outbounds=conf.get('outbounds')
if outbounds is None: outbounds=[]
if not isinstance(outbounds,list): raise SystemExit('outbounds must be an array')
outbounds=[o for o in outbounds if not (isinstance(o,dict) and o.get('tag')==tag)]
outbounds.append(ss)
if not modern and not any(isinstance(o,dict) and o.get('tag')=='block' for o in outbounds):
    outbounds.append({'type':'block','tag':'block'})
conf['outbounds']=outbounds

route=conf.get('route')
if route is None: route={}; conf['route']=route
if not isinstance(route,dict): raise SystemExit('route must be an object')
rules=route.get('rules')
if rules is None: rules=[]
if not isinstance(rules,list): raise SystemExit('route.rules must be an array')

# This tool owns the fixed outbound tag. Remove its old route rules first,
# then remove only UDP/443 block rules with the exact same old domain sets.
old_sets=[]
kept=[]
for rule in rules:
    if isinstance(rule,dict) and rule.get('outbound')==tag and isinstance(rule.get('domain_suffix'),list):
        old_sets.append(frozenset(rule['domain_suffix']))
    else:
        kept.append(rule)
rules=[]
for rule in kept:
    suffix=rule.get('domain_suffix') if isinstance(rule,dict) else None
    old_block=(isinstance(suffix,list) and frozenset(suffix) in old_sets and
               rule.get('network')=='udp' and rule.get('port')==443 and
               (rule.get('action')=='reject' or rule.get('outbound')=='block'))
    if not old_block: rules.append(rule)
last_action=-1
for i,rule in enumerate(rules):
    if isinstance(rule,dict) and rule.get('action') in ('sniff','hijack-dns','resolve'):
        last_action=i
block={'domain_suffix':wanted,'network':'udp','port':443}
if modern: block['action']='reject'
else: block['outbound']='block'
route_rule={'domain_suffix':wanted,'outbound':tag}
rules[last_action+1:last_action+1]=[block,route_rule]
route['rules']=rules
path.write_text(json.dumps(conf,indent=2,ensure_ascii=False)+'\n')
PY
  chmod 600 "$CANDIDATE"
}

check_candidate() {
  local args=() file replaced=0
  if [[ ${#CHECK_CONFIGS[@]} -eq 0 ]]; then
    args=(-c "$CANDIDATE")
  else
    for file in "${CHECK_CONFIGS[@]}"; do
      if [[ "$file" == "$CONFIG" ]]; then args+=(-c "$CANDIDATE"); replaced=1
      else args+=(-c "$file")
      fi
    done
    (( replaced == 1 )) || args+=(-c "$CANDIDATE")
  fi
  log "Checking generated configuration..."
  ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true \
  ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM=true \
  ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true \
    "$SB_BIN" check "${args[@]}" || die "Generated configuration failed sing-box check; original config was not changed."
  log "Configuration check passed."
}

unique_backup() {
  local dir base stamp
  dir="$(dirname "$CONFIG")"; base="$(basename "$CONFIG")"; stamp="$(date -u +%Y%m%d-%H%M%S)"
  mktemp "$dir/${base}.bak.${stamp}.XXXXXX"
}

prune_backups() {
  local dir base
  dir="$(dirname "$CONFIG")"; base="$(basename "$CONFIG")"
  python3 - "$dir" "$base" "$BACKUP_KEEP" <<'PY'
import pathlib, sys
directory=pathlib.Path(sys.argv[1]); base=sys.argv[2]; keep=int(sys.argv[3])
files=sorted(directory.glob(base+'.bak.*'), key=lambda p:p.stat().st_mtime_ns, reverse=True)
for path in files[keep:]:
    path.unlink(missing_ok=True)
PY
}

restore_config() {
  local backup="$1" dir staged
  [[ -r "$backup" ]] || die "Rollback failed: backup is missing or unreadable: $backup"
  dir="$(dirname "$CONFIG")"
  staged="$(mktemp "$dir/.singbox-ai-rollback.XXXXXX")" || die "Rollback failed: cannot create a staged file in $dir"
  if ! cp -a -- "$backup" "$staged"; then
    rm -f -- "$staged"
    die "Rollback failed while copying backup: $backup"
  fi
  if ! mv -f -- "$staged" "$CONFIG"; then
    rm -f -- "$staged"
    die "Rollback failed while replacing $CONFIG. Backup remains at: $backup"
  fi
}

install_candidate() {
  if (( DRY_RUN )); then
    local redacted
    redacted="$TMP_DIR/config.redacted.json"
    REDACT_SOURCE="$CANDIDATE" REDACT_TARGET="$redacted" python3 - <<'PY'
import json, os, pathlib
source=pathlib.Path(os.environ['REDACT_SOURCE'])
target=pathlib.Path(os.environ['REDACT_TARGET'])
conf=json.loads(source.read_text())
for outbound in conf.get('outbounds', []):
    if isinstance(outbound, dict) and outbound.get('tag') == 'ai-unlock-ss' and 'password' in outbound:
        outbound['password'] = '[REDACTED]'
target.write_text(json.dumps(conf, indent=2, ensure_ascii=False)+'\n')
PY
    diff -u --label "$CONFIG" --label "$CONFIG (generated, password redacted)" "$CONFIG" "$redacted" || true
    log "Dry run complete; original config unchanged."
    return
  fi
  local backup staged dir
  backup="$(unique_backup)"
  cp -a -- "$CONFIG" "$backup"
  chmod 600 "$backup" 2>/dev/null || true
  dir="$(dirname "$CONFIG")"
  staged="$(mktemp "$dir/.singbox-ai-unlock.XXXXXX")"
  cp -- "$CANDIDATE" "$staged"
  chmod --reference="$CONFIG" "$staged" 2>/dev/null || chmod 600 "$staged"
  chown --reference="$CONFIG" "$staged" 2>/dev/null || true
  mv -f -- "$staged" "$CONFIG"
  prune_backups
  log "Installed AI routing config. Backup: $backup"

  if (( NO_RESTART )); then
    log "Restart skipped (--no-restart)."
    return
  fi
  if [[ -z "$SERVICE" ]]; then
    warn "No service detected; restart sing-box manually."
    return
  fi
  if ! systemctl restart "$SERVICE.service"; then
    restore_config "$backup"
    systemctl restart "$SERVICE.service" >/dev/null 2>&1 || warn "Original config restored, but $SERVICE.service still failed to restart."
    die "Restart failed; original config restored from $backup."
  fi
  local attempt
  for attempt in 1 2 3 4 5; do
    : "$attempt"
    systemctl is-active --quiet "$SERVICE.service" && { log "$SERVICE.service is active."; return; }
    sleep 1
  done
  restore_config "$backup"
  systemctl restart "$SERVICE.service" >/dev/null 2>&1 || warn "Original config restored, but $SERVICE.service still failed to restart."
  die "Service did not become active; original config restored from $backup."
}

main() {
  parse_args "$@"
  need_cmd python3
  need_cmd mktemp
  find_singbox
  detect_service
  detect_configs
  prompt_ss_url
  parse_ss_url
  validate_ss
  (( DRY_RUN )) || need_root
  make_candidate
  check_candidate
  install_candidate
  log "AI domains now route through Shadowsocks outbound: $OUTBOUND_TAG"
}

main "$@"
