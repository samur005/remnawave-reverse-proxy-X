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

echo "All provision helper tests passed."
