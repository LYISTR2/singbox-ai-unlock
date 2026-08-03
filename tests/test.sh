#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/ai_singbox_unlock.sh"
TMP="$(mktemp -d /tmp/singbox-ai-unlock-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
PASS=0

ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }

make_env() {
  local name="$1" version="${2:-1.11.15}"
  local dir="$TMP/$name"
  mkdir -p "$dir/bin" "$dir/etc"
  cat >"$dir/bin/sing-box" <<EOF
#!/bin/sh
if [ "\$1" = version ]; then echo "sing-box version $version"; exit 0; fi
if [ "\$1" = check ]; then
  printf '%s\n' "\$@" > "$dir/check.args"
  while [ "\$#" -gt 0 ]; do
    if [ "\$1" = -c ]; then shift; python3 -m json.tool "\$1" >/dev/null || exit 1; fi
    shift
  done
  [ ! -f "$dir/fail-check" ]
  exit
fi
exit 0
EOF
  chmod +x "$dir/bin/sing-box"
  cat >"$dir/bin/systemctl" <<EOF
#!/bin/sh
case "\$1" in
  cat) [ "\$2" = sing-box.service ] && exit 0; exit 1 ;;
  show) printf '{ path = $dir/bin/sing-box ; argv[] = { $dir/bin/sing-box ; run ; -c ; $dir/etc/config.json ; -c ; $dir/etc/relay.json ; } ; ignore_errors = no ; }\n'; exit 0 ;;
  list-unit-files) printf 'sing-box.service enabled\n'; exit 0 ;;
  restart) printf '%s\n' "\$@" >> "$dir/restarts"; [ ! -f "$dir/fail-restart" ]; exit ;;
  is-active) [ ! -f "$dir/inactive" ]; exit ;;
esac
exit 1
EOF
  chmod +x "$dir/bin/systemctl"
  printf '%s\n' "$dir"
}

base_config() {
  cat <<'JSON'
{
  "log": {"level": "info"},
  "outbounds": [
    {"type": "socks", "tag": "existing-proxy", "server": "127.0.0.1", "server_port": 1080}
  ],
  "route": {
    "rules": [
      {"action": "sniff"},
      {"domain_suffix": ["openai.com", "chatgpt.com"], "outbound": "corporate-proxy"},
      {"domain_suffix": ["example.com"], "outbound": "existing-proxy"}
    ]
  }
}
JSON
}

ss_url='ss://YWVzLTEyOC1nY206cGFzcw@127.0.0.1:8388#test'

# 1. Auto-detection, preservation, modern config and idempotency.
dir="$(make_env modern)"
base_config >"$dir/etc/config.json"; printf '{}\n' >"$dir/etc/relay.json"
PATH="$dir/bin:$PATH" SS_URL="$ss_url" bash "$SCRIPT"
python3 - "$dir/etc/config.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
assert 'final' not in c['route']
assert [o['tag'] for o in c['outbounds']] == ['existing-proxy','ai-unlock-ss']
assert any(r.get('outbound')=='corporate-proxy' for r in c['route']['rules'])
ai=[r for r in c['route']['rules'] if r.get('outbound')=='ai-unlock-ss']
block=[r for r in c['route']['rules'] if r.get('action')=='reject' and r.get('network')=='udp']
assert len(ai)==len(block)==1
assert c['route']['rules'][0].get('action')=='sniff'
PY
ok "auto-detect service/config; preserve normal routing and user rules"
first_hash="$(sha256sum "$dir/etc/config.json" | cut -d' ' -f1)"
PATH="$dir/bin:$PATH" SS_URL="$ss_url" bash "$SCRIPT" --no-restart
second_hash="$(sha256sum "$dir/etc/config.json" | cut -d' ' -f1)"
[[ "$first_hash" == "$second_hash" ]] || fail "idempotent repeated run"
ok "idempotent repeated run"
[[ -s "$dir/check.args" ]] || fail "check uses discovered service config set"
ok "check uses discovered service config set"

# Changing extra domains must replace, not duplicate, the generated pair.
PATH="$dir/bin:$PATH" SS_URL="$ss_url" bash "$SCRIPT" --add-domain mistral.ai --no-restart >/dev/null
python3 - "$dir/etc/config.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
ai=[r for r in c['route']['rules'] if r.get('outbound')=='ai-unlock-ss']
blocks=[r for r in c['route']['rules'] if r.get('network')=='udp' and r.get('port')==443 and (r.get('action')=='reject' or r.get('outbound')=='block')]
assert len(ai)==len(blocks)==1 and 'mistral.ai' in ai[0]['domain_suffix']
PY
ok "changing extra domains replaces generated rules without duplicates"

# 2. Dry-run is read-only.
dir="$(make_env dry)"; base_config >"$dir/etc/config.json"; printf '{}\n' >"$dir/etc/relay.json"
before="$(sha256sum "$dir/etc/config.json")"
dry_secret='DryRunSecret_Z8x'
dry_encoded="$(python3 -c 'import base64; print(base64.urlsafe_b64encode(b"aes-128-gcm:'"$dry_secret"'").decode().rstrip("="))')"
PATH="$dir/bin:$PATH" bash "$SCRIPT" --ss-url "ss://${dry_encoded}@127.0.0.1:8388" --dry-run >"$dir/diff"
after="$(sha256sum "$dir/etc/config.json")"
[[ "$before" == "$after" && -s "$dir/diff" ]] || fail "dry-run leaves config unchanged"
ok "dry-run leaves config unchanged"
if grep -Fq "$dry_secret" "$dir/diff"; then fail "dry-run leaked SS password"; fi
grep -Fq '[REDACTED]' "$dir/diff" || fail "dry-run did not show a redaction marker"
ok "dry-run redacts SS password"

# 3. Check failure never changes the live config.
dir="$(make_env checkfail)"; base_config >"$dir/etc/config.json"; printf '{}\n' >"$dir/etc/relay.json"; touch "$dir/fail-check"
before="$(sha256sum "$dir/etc/config.json")"
if PATH="$dir/bin:$PATH" SS_URL="$ss_url" bash "$SCRIPT" >/dev/null 2>&1; then fail "check failure should abort"; fi
after="$(sha256sum "$dir/etc/config.json")"
[[ "$before" == "$after" ]] || fail "failed check leaves live config untouched"
ok "failed check leaves live config untouched"

# 4. Restart failure restores original.
dir="$(make_env restartfail)"; base_config >"$dir/etc/config.json"; printf '{}\n' >"$dir/etc/relay.json"; touch "$dir/fail-restart"
cp "$dir/etc/config.json" "$dir/original"
if PATH="$dir/bin:$PATH" SS_URL="$ss_url" bash "$SCRIPT" >/dev/null 2>&1; then fail "restart failure should abort"; fi
cmp -s "$dir/original" "$dir/etc/config.json" || fail "restart failure restores original config"
ok "restart failure restores original config"

# 5. Unique backups under same second.
dir="$(make_env backups)"; base_config >"$dir/etc/config.json"; printf '{}\n' >"$dir/etc/relay.json"
PATH="$dir/bin:$PATH" SS_URL="$ss_url" bash "$SCRIPT" --no-restart >/dev/null
PATH="$dir/bin:$PATH" SS_URL="$ss_url" bash "$SCRIPT" --no-restart >/dev/null
count="$(find "$dir/etc" -maxdepth 1 -name 'config.json.bak.*' | wc -l)"
[[ "$count" -eq 2 ]] || fail "same-second runs create unique backups"
ok "same-second runs create unique backups"

# 6. Legacy syntax.
dir="$(make_env legacy 1.10.7)"; base_config >"$dir/etc/config.json"; printf '{}\n' >"$dir/etc/relay.json"
PATH="$dir/bin:$PATH" SS_URL="$ss_url" bash "$SCRIPT" --no-restart >/dev/null
python3 - "$dir/etc/config.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
assert any(o.get('tag')=='block' and o.get('type')=='block' for o in c['outbounds'])
assert any(r.get('outbound')=='block' and r.get('network')=='udp' for r in c['route']['rules'])
PY
ok "sing-box 1.10 legacy block syntax"

# 7. Extra domain and IPv6 SS parser.
dir="$(make_env ipv6)"; base_config >"$dir/etc/config.json"; printf '{}\n' >"$dir/etc/relay.json"
ipv6='ss://YWVzLTEyOC1nY206cGFzcw@[2001:db8::1]:443#v6'
PATH="$dir/bin:$PATH" bash "$SCRIPT" --ss-url "$ipv6" --add-domain mistral.ai,api.mistral.ai --no-restart >/dev/null
python3 - "$dir/etc/config.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); o=next(x for x in c['outbounds'] if x.get('tag')=='ai-unlock-ss')
assert o['server']=='2001:db8::1' and o['server_port']==443
r=next(x for x in c['route']['rules'] if x.get('outbound')=='ai-unlock-ss')
assert 'mistral.ai' in r['domain_suffix'] and 'api.mistral.ai' not in r['domain_suffix']
PY
ok "IPv6 SS parsing and extra-domain suffix dedupe"

# 8. Secret does not appear in normal output.
dir="$(make_env secret)"; base_config >"$dir/etc/config.json"; printf '{}\n' >"$dir/etc/relay.json"
secret='DistinctSecret_9zQ'
encoded="$(python3 -c 'import base64; print(base64.urlsafe_b64encode(b"aes-128-gcm:'"$secret"'").decode().rstrip("="))')"
PATH="$dir/bin:$PATH" bash "$SCRIPT" --ss-url "ss://${encoded}@127.0.0.1:8388" --no-restart >"$dir/out" 2>&1
if grep -Fq "$secret" "$dir/out"; then fail "secret leaked to stdout"; fi
ok "normal output does not expose SS password"

printf '\nALL %d TESTS PASSED\n' "$PASS"
