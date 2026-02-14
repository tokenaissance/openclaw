#!/usr/bin/env bash
set -euo pipefail

# Closed-loop helper:
# - Finds an iOS node on the current gateway
# - Prints connection + lastPong + lifecycle + lastLocation in a tight loop
#
# Usage:
#   scripts/dev/ios-comms-loop.sh            # auto-pick first iOS node
#   scripts/dev/ios-comms-loop.sh <nodeId>   # explicit

NODE_ID="${1:-}"

if [[ -z "${NODE_ID}" ]]; then
  NODE_ID="$(
    {
      # Preferred: status JSON includes a "nodes" array with live connectivity fields.
      openclaw nodes status --json 2>/dev/null \
        | node -e 'const fs=require("fs");const j=JSON.parse(fs.readFileSync(0,"utf8"));const nodes=j.nodes||[];const ios=nodes.find(n=>String(n.platform||"").toLowerCase().includes("ios")||String(n.deviceFamily||"").toLowerCase().includes("iphone")||String(n.displayName||"").toLowerCase().includes("iphone")); if(ios?.nodeId){process.stdout.write(String(ios.nodeId)); process.exit(0)} process.exit(1);' \
      || true
    } | head -n 1
  )"
fi

if [[ -z "${NODE_ID}" ]]; then
  NODE_ID="$(
    {
      # Fallback: pairing list JSON uses a "paired" array.
      openclaw nodes list --json 2>/dev/null \
        | node -e 'const fs=require("fs");const j=JSON.parse(fs.readFileSync(0,"utf8"));const paired=j.paired||[];const ios=paired.find(n=>String(n.platform||"").toLowerCase().includes("ios")||String(n.deviceFamily||"").toLowerCase().includes("iphone")||String(n.displayName||"").toLowerCase().includes("iphone")); if(ios?.nodeId){process.stdout.write(String(ios.nodeId)); process.exit(0)} process.exit(1);' \
      || true
    } | head -n 1
  )"
fi

if [[ -z "${NODE_ID}" ]]; then
  echo "error: no iOS node found (pass nodeId explicitly)" >&2
  exit 2
fi

echo "nodeId=${NODE_ID}"
echo "tip: background/foreground the app and watch connected/lifecycle flip; enable Settings -> Background Location Reporting to watch lastLocation update."
echo

while true; do
  openclaw nodes describe --node "${NODE_ID}" --json \
    | node -e '
      const fs=require("fs");
      const j=JSON.parse(fs.readFileSync(0,"utf8"));
      const now=Date.now();
      const fmtMs=(ms)=>typeof ms==="number"?`${Math.round((now-ms)/1000)}s ago`:"-";
      const loc=j.lastLocation||null;
      const lifecycle=j.lifecycle||null;
      const parts=[];
      parts.push(`connected=${j.connected?"yes":"no"}`);
      parts.push(`lastPong=${fmtMs(j.lastPongAtMs)}`);
      parts.push(`lifecycle=${lifecycle?`${lifecycle.state} (${fmtMs(lifecycle.updatedAtMs)})`:"-"}`);
      parts.push(`loc=${loc?`${loc.lat.toFixed(5)},${loc.lon.toFixed(5)} (${fmtMs(loc.tsMs)})`:"-"}`);
      process.stdout.write(parts.join(" | ")+"\\n");
    '
  sleep 2
done
