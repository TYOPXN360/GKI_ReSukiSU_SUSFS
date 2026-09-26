#!/usr/bin/env bash
# 升级到谷歌官方最新开发分支
#   默认 common-android16-6.12（dev tip，非 -lts 稳定分支）
#   BRANCH=common-android16-6.12-lts scripts/upgrade_kernel.sh   # 用 LTS
set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=local-env.sh
source "$SCRIPT_DIR/local-env.sh"

BRANCH="${BRANCH:-common-android16-6.12}"
log "升级内核源码到: $BRANCH"
log "当前 pristine-base: $(git -C "$COMMON" rev-parse --short=13 pristine-base 2>/dev/null || echo '未打标')"

BRANCH="$BRANCH" FORCE=1 exec "$SCRIPT_DIR/recover_sync.sh"
