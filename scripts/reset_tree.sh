#!/usr/bin/env bash
# 把内核源码树重置到纯净上游状态
#
# 关键：必须 reset 到 pristine-base 标签（上游 commit），
# 而不是 HEAD —— 因为会周期性 git commit 保存"已打补丁"的树状态，
# HEAD 往往就是补丁后的状态，reset --hard HEAD 会把补丁一起还原，
# 导致后续构建重复套用补丁（日志里出现 "Reversed or previously applied"）。
set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=local-env.sh
source "$SCRIPT_DIR/local-env.sh"

BASE="${PRISTINE_REF:-pristine-base}"
git -C "$COMMON" rev-parse --verify "$BASE" >/dev/null 2>&1 \
  || die "缺少 $BASE 标签，请先运行 scripts/recover_sync.sh 或手工打标：git -C common tag $BASE <上游commit>"

cd "$COMMON"
git reset --hard "$BASE" >/dev/null
git clean -xfdq
find . -name "*.rej" -delete 2>/dev/null
rm -f 50_add_susfs_in_gki-*.patch ntsync_compat_*.patch

cd "$KERNEL_ROOT"
# 构建脚本生成的目录/软链（含断电可能留下的悬空软链）一并清理
rm -rf NoMount Baseband-guard out bazel-* hs_err_pid*.log KernelSU
rm -f common/drivers/kernelsu common/security/baseband-guard
git -C common checkout -- . 2>/dev/null || true

# 从本地缓存恢复 ReSukiSU（git clone 走代理传大 pack 容易断，改用 tarball）
if [ -s "$LOCAL_CACHE/ReSukiSU-main.tgz" ]; then
  tar xzf "$LOCAL_CACHE/ReSukiSU-main.tgz"
  ok "已从本地缓存恢复 KernelSU"
fi

N=$(git -C common status --short | wc -l)
[ "$N" -eq 0 ] || die "重置不干净，仍有 $N 处改动"
ok "源码树已重置到 $BASE（0 改动）"
