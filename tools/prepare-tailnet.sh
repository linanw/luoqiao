#!/bin/sh
# Optional download fallback; checksums remain verified through sum.golang.org.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 "$ROOT/tools/module-download-proxy.py" &
proxy_pid=$!
trap 'kill "$proxy_pid" 2>/dev/null || true' EXIT INT TERM
python3 - <<'PYWAIT'
import time, urllib.request
for attempt in range(50):
    try:
        urllib.request.urlopen('http://127.0.0.1:18763/ready', timeout=1).close()
        break
    except OSError:
        time.sleep(0.1)
else:
    raise SystemExit('Module download proxy failed to start')
PYWAIT
cd "$ROOT/tailnet"
GOPROXY=http://127.0.0.1:18763 "${WIREGUARD_OHOS_GO:-$ROOT/.toolchain/ohos-go/bin/go}" mod tidy
