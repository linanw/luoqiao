#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination=${1:-"$repo_root/.toolchain/ohos-go"}
revision=302a5306b6fad2f47196360b82561d1db1f954cf
repository=https://gitcode.com/openharmony-sig/ohos_golang_go.git
archive_release=go1.27.1-ohos

if [ ! -d "$destination/.git" ]; then
    if [ -e "$destination" ]; then
        # The distributed release includes its standard-library sources but no
        # Git metadata. Accept this known release only; the patch below must
        # still match exactly before any build can proceed.
        installed_release=$(sed -n '1p' "$destination/VERSION" 2>/dev/null || true)
        if [ "$installed_release" != "$archive_release" ] || [ ! -x "$destination/bin/go" ]; then
            printf '%s\n' "Choose a new destination for the OpenHarmony Go toolchain: $destination" >&2
            exit 1
        fi
    else
        git init -- "$destination"
    fi
fi

if [ -d "$destination/.git" ]; then
    current=$(git -C "$destination" rev-parse --verify HEAD 2>/dev/null || true)
    if [ -z "$current" ]; then
        git -C "$destination" fetch --depth 1 "$repository" "$revision"
        git -C "$destination" checkout --detach FETCH_HEAD
    elif [ "$current" != "$revision" ]; then
        printf '%s\n' "Expected revision $revision at $destination. Choose a new destination." >&2
        exit 1
    fi
fi
destination=$(CDPATH= cd -- "$destination" && pwd)

# The pinned fork leaks an ioctl socket and a getifaddrs allocation each time
# net.Interfaces/Interface.Addrs runs. Tailnet polls these throughout a session.
# Keep the source fix reproducible and reject an incompatible local toolchain.
interface_patch="$repo_root/tools/patches/openharmony-go-interface-resources.patch"
if git apply --unsafe-paths --directory="$destination" --reverse --check "$interface_patch" >/dev/null 2>&1; then
    : # Already applied; do not touch source timestamps on repeated preparation.
elif git apply --unsafe-paths --directory="$destination" --check "$interface_patch"; then
    git apply --unsafe-paths --directory="$destination" "$interface_patch"
else
    printf '%s\n' "Cannot apply the OpenHarmony interface resource fix at $destination." >&2
    exit 1
fi

if [ ! -x "$destination/bin/go" ] ||
    ! GOTOOLCHAIN=local "$destination/bin/go" tool dist list | grep -qx 'openharmony/arm64'; then
    : "${GOROOT_BOOTSTRAP:=$(go env GOROOT)}"
    export GOROOT_BOOTSTRAP
    (cd "$destination/src" && GOTOOLCHAIN=local ./make.bash)
fi
printf 'OpenHarmony Go compiler: %s\n' "$destination/bin/go"
