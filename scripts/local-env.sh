#!/usr/bin/env bash
# 本地构建公共配置（被 scripts/ 下各脚本 source）
#
# 所有路径均可通过环境变量覆盖，默认基于本文件位置自动推导，
# 因此把仓库 clone 到任意位置都能直接使用。
#
#   GIT_ROOT        仓库根目录（默认：脚本所在目录的上一级）
#   LOCAL_WORK      本地工作区，放源码与产物（默认：$GIT_ROOT/.local-build）
#   LOCAL_TOOLS     免 root 自备工具（默认：$LOCAL_WORK/tools）
#   KERNEL_SRC_NAME 内核源码同步目录名（默认：android16-6.12-92）

set -eo pipefail

LOCAL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_ROOT="${GIT_ROOT:-$(cd "$LOCAL_SCRIPT_DIR/.." && pwd)}"
LOCAL_WORK="${LOCAL_WORK:-$GIT_ROOT/.local-build}"
LOCAL_TOOLS="${LOCAL_TOOLS:-$LOCAL_WORK/tools}"
LOCAL_CACHE="${LOCAL_CACHE:-$LOCAL_WORK/cache}"
KERNEL_SRC_NAME="${KERNEL_SRC_NAME:-android16-6.12-92}"

# 源码与产物目录
KERNEL_ROOT="$LOCAL_WORK/$KERNEL_SRC_NAME"
COMMON="$KERNEL_ROOT/common"
OUT="$KERNEL_ROOT/out"
DEFCONFIG="$COMMON/arch/arm64/configs/gki_defconfig"
FRAG="$COMMON/arch/arm64/configs/ksu.fragment"

# 可写 HOME：ccache / pahole / git 凭据都装在这里。
# 优先级：LOCAL_HOME > 已有的 HOME > $LOCAL_WORK/home
# （原仓库若在只读文件系统上，已有的 HOME 不可写时才需要指到 LOCAL_HOME）
if [ -z "${LOCAL_HOME:-}" ] && { [ -z "${HOME:-}" ] || [ ! -w "${HOME:-/nonexistent}" ]; }; then
  LOCAL_HOME="$LOCAL_WORK/home"
fi
export HOME="${LOCAL_HOME:-${HOME:-$LOCAL_WORK/home}}"
mkdir -p "$HOME"
[ -w "$HOME" ] || die "HOME 不可写: $HOME（请设 LOCAL_HOME 指向可写目录）"

# 免 root 工具（cmake/zstd/cpio/pkgconf 等，见 docs/local-build.md）
# cmake 目录名可能是 cmake/ 或 cmake-<版本>/
for c in "$LOCAL_TOOLS"/cmake "$LOCAL_TOOLS"/cmake-*; do
  [ -x "$c/bin/cmake" ] && export PATH="$c/bin:$PATH" && break
done
[ -d "$LOCAL_TOOLS/root/usr/bin" ] && export PATH="$LOCAL_TOOLS/root/usr/bin:$PATH"
[ -d "$LOCAL_TOOLS/root/usr/lib/x86_64-linux-gnu" ] && \
  export LD_LIBRARY_PATH="$LOCAL_TOOLS/root/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"

# 代理（可选）
if [ -n "${PROXY:-}" ]; then
  export http_proxy="$PROXY" https_proxy="$PROXY"
  export HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY"
fi
export no_proxy="localhost,127.0.0.1"
export GIT_CLONE_PROTECTION_ACTIVE=false

export REPO="$LOCAL_WORK/git-repo/repo"

# git 全局设置
git config --global --add safe.directory '*' 2>/dev/null || true
git config --global user.email  "${GIT_USER_EMAIL:-builder@local}"   2>/dev/null || true
git config --global user.name   "${GIT_USER_NAME:-local builder}"    2>/dev/null || true
git config --global http.version HTTP/1.1
git config --global http.postBuffer 524288000
[ -n "${PROXY:-}" ] && git config --global http.proxy "$PROXY" 2>/dev/null
export GIT_TERMINAL_PROMPT=0

# ---- 常用函数 ----
log()  { echo -e "[*] $*"; }
ok()   { echo -e "[+] $*"; }
warn() { echo -e "[!] $*"; }
die()  { echo -e "[-] $*" >&2; exit 1; }

retry() {
  local n="$1" d="$2"; shift 2
  local a=1
  until "$@"; do
    [ "$a" -ge "$n" ] && { echo "[-] 重试 $n 次仍失败: $*" >&2; return 1; }
    sleep $((d * a)); a=$((a + 1))
  done
}

# 下载：先本地缓存 → 镜像 → 官方
fetch_file() {
  local url="$1" dest="$2" mirror="${3:-}"
  if [ -s "$dest" ]; then log "使用缓存: $(basename "$dest")"; return 0; fi
  mkdir -p "$(dirname "$dest")"
  if [ -n "$mirror" ] && retry 3 5 curl -sSL -o "$dest" "$mirror"; then return 0; fi
  retry 4 10 curl -sSL -o "$dest" "$url" || return 1
  [ -s "$dest" ]
}

check_pristine() {
  local n
  n=$(git -C "$COMMON" status --short 2>/dev/null | wc -l)
  [ "$n" -eq 0 ] || die "源码树有 $n 处改动，请先运行 scripts/reset_tree.sh"
}
