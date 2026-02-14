#!/usr/bin/env bash
set -euo pipefail

# Closed-loop-ish Talk/PTT tester:
# - Finds the connected iOS node via the gateway
# - Invokes talk PTT commands via the CLI
# - Pulls iOS diagnostics log via devicectl so we can see STT->chat->TTS stages
#
# You still need to:
# - Have the iOS app connected + paired to the gateway
# - Speak when prompted

DEVICE_NAME_OR_ID="${DEVICE_NAME_OR_ID:-MB-iPhone15}"
BUNDLE_ID="${BUNDLE_ID:-ai.openclaw.ios.dev.mariano.test}"
DEST_LOG="${DEST_LOG:-/tmp/openclaw-gateway.log}"
MODE="${1:-startstop}" # startstop | once

PHRASE="${PHRASE:-"test one two three"}"
PTT_SECONDS="${PTT_SECONDS:-6}"
POST_SECONDS="${POST_SECONDS:-14}"

die() {
  echo "error: $*" >&2
  exit 1
}

need_bin() {
  command -v "$1" >/dev/null 2>&1 || die "missing required binary: $1"
}

need_bin pnpm
need_bin xcrun
need_bin python3

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

if [[ ! -x scripts/dev/ios-pull-gateway-log.sh ]]; then
  die "missing scripts/dev/ios-pull-gateway-log.sh"
fi

if [[ "$MODE" != "startstop" && "$MODE" != "once" ]]; then
  cat >&2 <<EOF
Usage:
  scripts/dev/ios-talk-loop.sh [startstop|once]

Env overrides:
  DEVICE_NAME_OR_ID=MB-iPhone15
  BUNDLE_ID=ai.openclaw.ios.dev.mariano.test
  PHRASE="hello"
  PTT_SECONDS=6
  POST_SECONDS=14
  DEST_LOG=/tmp/openclaw-gateway.log

Notes:
  - startstop: invokes talk.ptt.start, waits PTT_SECONDS, invokes talk.ptt.stop
  - once: invokes talk.ptt.once (silence endpointing, 12s max in-app)
EOF
  exit 2
fi

nodes_json="$(pnpm -s openclaw nodes list --json | tail -n +2)"

node_id="$(
  python3 - <<'PY' "$nodes_json"
import json,sys
raw = sys.argv[1]
obj = json.loads(raw)
paired = obj.get("paired") or []
for n in paired:
    platform = (n.get("platform") or "").lower()
    if "ios" in platform:
        print(n.get("nodeId") or "")
        sys.exit(0)
print("")
PY
)"

if [[ -z "$node_id" ]]; then
  cat >&2 <<EOF
No paired iOS node found on the gateway.

Do this on your phone:
1) In Telegram, message your bot: /pair
2) Paste the setup code into the iOS app -> Settings -> Gateway -> Connect
3) Back in Telegram: /pair approve

Then rerun:
  scripts/dev/ios-talk-loop.sh $MODE
EOF
  exit 3
fi

echo "iOS node: $node_id"
echo "Device: $DEVICE_NAME_OR_ID"
echo "Bundle: $BUNDLE_ID"

# Pull a baseline log snapshot (best-effort).
scripts/dev/ios-pull-gateway-log.sh "$DEVICE_NAME_OR_ID" "$BUNDLE_ID" "$DEST_LOG" >/dev/null 2>&1 || true

run_started_iso="$(python3 - <<'PY'
from datetime import datetime,timezone
print(datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00","Z"))
PY
)"

echo ""
if [[ "$MODE" == "startstop" ]]; then
  echo "PTT start/stop run"
  echo "When I print GO, speak: \"$PHRASE\""
  echo "Speak for ~${PTT_SECONDS}s, then stop."
  echo ""

  pnpm -s openclaw nodes invoke --node "$node_id" --command talk.ptt.start --params '{}' --json
  echo "GO"
  sleep "$PTT_SECONDS"
  pnpm -s openclaw nodes invoke --node "$node_id" --command talk.ptt.stop --params '{}' --json
else
  echo "PTT once run"
  echo "When I print GO, speak: \"$PHRASE\""
  echo "Stop talking, then wait for the assistant to talk back."
  echo ""

  echo "GO"
  pnpm -s openclaw nodes invoke --node "$node_id" --command talk.ptt.once --params '{}' --json
fi

echo ""
echo "Waiting ${POST_SECONDS}s for chat->TTS to run..."
sleep "$POST_SECONDS"

scripts/dev/ios-pull-gateway-log.sh "$DEVICE_NAME_OR_ID" "$BUNDLE_ID" "$DEST_LOG" >/dev/null 2>&1 || true

echo ""
echo "iOS talk log slice since $run_started_iso:"
python3 - <<'PY' "$DEST_LOG" "$run_started_iso"
import re,sys
path = sys.argv[1]
since = sys.argv[2]
ts_re = re.compile(r"^\\[(?P<ts>[^\\]]+)\\]\\s*(?P<msg>.*)$")
try:
    data = open(path, "r", encoding="utf-8", errors="replace").read().splitlines()
except FileNotFoundError:
    print("(log not found; devicectl pull likely failed)")
    sys.exit(0)

out = []
for line in data:
    m = ts_re.match(line)
    if not m:
        continue
    ts = m.group("ts")
    if ts < since:
        continue
    msg = m.group("msg")
    if "talk " in msg or msg.startswith("talk") or "talk:" in msg:
        out.append(line)

if not out:
    print("(no talk logs found in slice)")
else:
    # Keep it readable; tail the most recent chunk.
    for line in out[-160:]:
        print(line)
PY

