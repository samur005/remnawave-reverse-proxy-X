#!/bin/bash
# Dry-run checks for Remnawave X turnkey helpers. No API calls, no VPS changes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/src/modules/provision_remnawave_x.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# Official edition must skip turnkey work.
REMN_EDITION=official
rwx_is_remnawave_x_edition && fail "official edition should not be treated as Remnawave X"
pass "official edition is skipped"

REMN_EDITION=custom
rwx_is_remnawave_x_edition || fail "custom edition should be Remnawave X"
pass "custom edition is Remnawave X"

rwx_is_private_address "172.30.0.1" || fail "172.30.0.1 must be private"
rwx_is_private_address "172.30.0.1:2222" || fail "172.30.0.1:2222 must be private"
rwx_is_private_address "10.0.0.2" || fail "10.0.0.2 must be private"
rwx_is_private_address "192.168.1.1" || fail "192.168.1.1 must be private"
rwx_is_private_address "127.0.0.1" || fail "127.0.0.1 must be private"
rwx_is_private_address "localhost" || fail "localhost must be private"
rwx_is_private_address "::1" || fail "::1 must be private"

if rwx_is_private_address "node.144.31.53.140.sslip.io"; then
    fail "hostname must stay public"
fi
if rwx_is_private_address "10.example.com"; then
    fail "10.example.com is a hostname, not a private IP"
fi
if rwx_is_private_address "8.8.8.8"; then
    fail "8.8.8.8 must be public"
fi
if rwx_is_private_address "144.31.53.140"; then
    fail "public IPv4 must be public"
fi
pass "private/public address checks"

# Start at 8443, skip reserved and already used ports.
picked="$(rwx_pick_port 8443 "22 80 443 56000 56001 56003 8443 10002")"
[ "$picked" = "8444" ] || fail "expected 8444 when 8443 is taken, got $picked"
picked2="$(rwx_pick_port 10002 "22 80 443 56000 10002")"
[ "$picked2" = "10003" ] || fail "expected 10003 when 10002 is taken, got $picked2"
pass "port picker skips reserved and taken ports ($picked, $picked2)"

# Recover the selfsteal domain from a combined panel+node layout.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/docker-compose.yml" <<'EOF'
      environment:
          - SELF_STEAL_DOMAIN=node.example.com
          - PANEL_DOMAIN=panel.example.com
EOF
got="$(rwx_local_public_host "$tmp")"
[ "$got" = "node.example.com" ] || fail "expected node.example.com from compose, got $got"
pass "local public host from Caddy compose"

tmp2=$(mktemp -d)
cat > "$tmp2/.env" <<'EOF'
PANEL_DOMAIN=panel.example.com
SUB_PUBLIC_DOMAIN=sub.example.com
EOF
cat > "$tmp2/nginx.conf" <<'EOF'
server {
    server_name panel.example.com;
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
}
server {
    server_name sub.example.com;
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
}
server {
    server_name node.example.com;
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    root /var/www/html;
}
server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol default_server;
    server_name _;
}
EOF
got="$(rwx_local_public_host "$tmp2")"
[ "$got" = "node.example.com" ] || fail "expected node.example.com from nginx.conf, got $got"
rm -rf "$tmp2"
pass "local public host from nginx selfsteal server_name"

# Menu entry: no local panel, or Official edition, must show a clear skip
# and must not crash. LANG is the locale string in this dry-run; give
# rwx_msg an associative array so set -u does not trip on LANG[$key].
declare -A LANG=()
COLOR_YELLOW=""
COLOR_RESET=""
COLOR_GREEN=""
panel_is_installed() { return 1; }
out="$(manage_remnawave_x_turnkey)"
echo "$out" | grep -q "needs the panel on this server" || fail "no-panel path should show RWX_PROVISION_NO_PANEL, got: $out"
pass "menu turnkey reports missing panel"

panel_is_installed() { return 0; }
REMN_EDITION=official
out="$(manage_remnawave_x_turnkey)"
echo "$out" | grep -q "skipped (Official edition or no node)" || fail "official edition should show RWX_PROVISION_SKIP, got: $out"
pass "menu turnkey skips Official edition"

echo "All provision helper tests passed."
