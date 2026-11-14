#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEVECO_HOME=${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}
export JAVA_HOME="$DEVECO_HOME/jbr/Contents/Home"
export DEVECO_SDK_HOME="$DEVECO_HOME/sdk"
export PATH="$JAVA_HOME/bin:$DEVECO_HOME/tools/node/bin:$DEVECO_HOME/tools/ohpm/bin:$PATH"
cd "$ROOT"
"$ROOT/tools/prepare-ohos-go.sh"
"$DEVECO_HOME/tools/ohpm/bin/ohpm" install --all
"$DEVECO_HOME/tools/hvigor/bin/hvigorw" assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
