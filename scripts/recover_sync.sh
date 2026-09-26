#!/usr/bin/env bash
# 同步/恢复 AOSP 内核源码（repo manifest）
#
#   首次同步：  scripts/recover_sync.sh
#   断电损坏后：FORCE=1 scripts/recover_sync.sh     # 强制重拉 common
#   升级到最新：BRANCH=common-android16-6.12 scripts/upgrade_kernel.sh
set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=local-env.sh
source "$SCRIPT_DIR/local-env.sh"

BRANCH="${BRANCH:-common-android16-6.12}"
FORCE="${FORCE:-0}"

# repo 工具
if [ ! -x "$REPO" ]; then
  mkdir -p "$(dirname "$REPO")"
  log "下载 repo 工具..."
  fetch_file "https://storage.googleapis.com/git-repo-downloads/repo" "$REPO" \
    "https://ghfast.top/storage.googleapis.com/git-repo-downloads/repo" \
    || die "repo 工具下载失败"
  chmod 0755 "$REPO"
fi

if [ "$FORCE" = "1" ]; then
  warn "强制重拉 $KERNEL_SRC_NAME"
  rm -rf "$KERNEL_ROOT" "$KERNEL_ROOT.out" "$KERNEL_ROOT".out
fi
mkdir -p "$KERNEL_ROOT"

cd "$KERNEL_ROOT"
if [ ! -d .repo ]; then
  log "repo init: $BRANCH"
  "$REPO" init --depth=1 -u https://android.googlesource.com/kernel/manifest -b "$BRANCH" --repo-rev=v2.16
fi

log "repo sync（$BRANCH）..."
"$REPO" --trace sync -c "-j$(nproc --all)" --no-tags --fail-fast

SUB=$(awk '/^SUBLEVEL = / {print $3; exit}' common/Makefile)
ok "内核源码: 6.12.$SUB  ($(git -C common rev-parse --short=13 HEAD))"

# 打上纯净基线标签，供 scripts/reset_tree.sh 使用
if ! git -C common rev-parse --verify pristine-base >/dev/null 2>&1; then
  git -C common tag -f pristine-base HEAD
  ok "已创建 pristine-base 标签"
fi
echo "SYNC_DONE sublevel=$SUB"
