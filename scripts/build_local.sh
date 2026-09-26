#!/usr/bin/env bash
# ============================================================================
# 本地构建（脱离 GitHub Actions）
#
#   基础：ReSukiSU + SuSFS + Bypass(放宽模块版本校验) + 清空 KMI 受保护符号
#   可选：BBRv3 / NTSync / BBG防格机 / Droidspaces / LZ4-NEON / 调优 / netfilter
#
# 用法：
#   scripts/reset_tree.sh                  # 重置到纯净源码
#   scripts/build_local.sh                 # 默认全特性 + bazel + lto=none
#   USE_PERF=false scripts/build_local.sh  # 关掉性能补丁包
#
# 重要：6.12 上 thin/full LTO 都会导致内核无法启动（已实测，见提交说明），
#       因此 BUILD_METHOD=bazel + LTO_MODE=none 是唯一可用组合。
# ============================================================================
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=local-env.sh
source "$SCRIPT_DIR/local-env.sh"

ROOT="\$LOCAL_WORK"
PROJ="\$GIT_ROOT"
SUSFS4KSU="\$ROOT/susfs4ksu"
ACTION_BUILD="\$ROOT/Action-Build"
ANYKERNEL3="\$ROOT/AnyKernel3"
PERF_DIR="\${PERF_PATCH_DIR:-\$GIT_ROOT/../GKID-Kernels/kernel-patches/common}"
ZRAM_DIR="\$GIT_ROOT/zram"
BBRV3_PATCH="\${BBRV3_PATCH:-\$GIT_ROOT/patches/bbrv3-6.12.patch}"

ANDROID_VERSION=android16; KERNEL_VERSION=6.12; OS_PATCH_LEVEL=dev

# ---- 特性开关（均可用环境变量覆盖）----
FEAT_NTSYNC="\${FEAT_NTSYNC:-true}"           # NTSync 解禁
FEAT_BBG="\${FEAT_BBG:-true}"                 # BBG 防格机
FEAT_DROIDSPACES="\${FEAT_DROIDSPACES:-true}" # Droidspaces 容器
FEAT_BBRV3="\${FEAT_BBRV3:-true}"             # BBRv3
FEAT_LZ4_NEON="\${FEAT_LZ4_NEON:-true}"       # LZ4 1.10.0 + ARM64 NEON
FEAT_TUNING="\${FEAT_TUNING:-true}"           # HZ=300 + ZRAM
FEAT_NETFILTER="\${FEAT_NETFILTER:-true}"     # IP_SET 完整集 + IPv6 NAT + WESTWOOD/TTL
USE_PERF="\${USE_PERF:-true}"                 # GKID 性能补丁包

log "0/8 校验源码"
[ -d "$COMMON" ] || die "common 不存在，请先运行 upgrade_kernel.sh"
SUBLEVEL=$(awk '/^SUBLEVEL = / {print $3; exit}' "$COMMON/Makefile")
COMMIT=$(git -C "$COMMON" rev-parse --short=13 HEAD)
CURRENT_SUB="$SUBLEVEL"
ok "源码 6.12.$SUBLEVEL ($COMMIT)"

log "1/8 克隆依赖"
cd "$ROOT"
[ -d "$ACTION_BUILD/.git" ] || retry 4 10 git clone --depth=1 https://github.com/Numbersf/Action-Build.git
[ -d "$SUSFS4KSU/.git" ] || retry 6 15 git clone --depth=1 https://gitlab.com/simonpunk/susfs4ksu.git -b "gki-$ANDROID_VERSION-$KERNEL_VERSION"
if [ "$FEAT_DROIDSPACES" = "true" ]; then
  [ -d "$ROOT/Droidspaces-OSS" ] || retry 4 10 git clone --depth 1 https://github.com/ravindu644/Droidspaces-OSS.git "$ROOT/Droidspaces-OSS"
fi
DROIDSPACES_PATCHES="$ROOT/Droidspaces-OSS/Documentation/resources/kernel-patches/GKI"

log "2/8 备份原始 defconfig + CVE 修复链"
cp "$DEFCONFIG" "$DEFCONFIG.orig"
cd "$COMMON"
bash "$PROJ/security_patch/apply_cve_2026_43499.sh" "$KERNEL_VERSION" "$CURRENT_SUB" "$PROJ/security_patch" \
  || warn "CVE 修复链脚本返回非零（可能已应用）"

log "3/8 添加 ReSukiSU"
cd "$KERNEL_ROOT"
# setup.sh 内部会执行 git clone + git pull，网络不稳时必然挂起。
# 改为：用 tarball 预置的 KernelSU（内容与 GitHub main 分支一致），
#       手动复现 setup.sh 的集成步骤（软链 + Makefile + Kconfig），全程不依赖网络。
if [ ! -d "$KERNEL_ROOT/KernelSU/kernel" ]; then
  die "KernelSU 未预置：请先用 codeload tarball 下载解包并 git init 初始化"
fi
rm -f "$KERNEL_ROOT/common/drivers/kernelsu"
ln -sf ../../KernelSU/kernel "$KERNEL_ROOT/common/drivers/kernelsu"
ok "KSU 软链: common/drivers/kernelsu -> ../../KernelSU/kernel"

DRV_MAKE="$KERNEL_ROOT/common/drivers/Makefile"
DRV_KCFG="$KERNEL_ROOT/common/drivers/Kconfig"
grep -q "kernelsu" "$DRV_MAKE" || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$DRV_MAKE"
grep -q 'source "drivers/kernelsu/Kconfig"' "$DRV_KCFG" || sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' "$DRV_KCFG"
ok "drivers/Makefile 与 drivers/Kconfig 已注入"
ok "KSU 版本: $(git -C KernelSU log --oneline -1 2>/dev/null || echo '本地导入')"

log "4/8 应用 SuSFS 补丁"
cd "$KERNEL_ROOT"
cp "$SUSFS4KSU/kernel_patches/50_add_susfs_in_gki-$ANDROID_VERSION-$KERNEL_VERSION.patch" ./common/
cp "$SUSFS4KSU/kernel_patches/fs/"* ./common/fs/
cp "$SUSFS4KSU/kernel_patches/include/linux/"* ./common/include/linux/
cd "$COMMON"
# 6.12 且 SUBLEVEL>=58：临时删掉 exec.c 的 dma-buf.h 让补丁上下文匹配，打完再还原
if [ "$CURRENT_SUB" -ge 58 ]; then
  sed -i '/^#include <linux\/dma-buf.h>$/d' fs/exec.c
fi
patch -p1 < "50_add_susfs_in_gki-$ANDROID_VERSION-$KERNEL_VERSION.patch" || warn "SuSFS 主补丁有 hunk 失败（项目本身容忍）"
if [ "$CURRENT_SUB" -ge 58 ] && ! grep -qF '#include <linux/dma-buf.h>' fs/exec.c; then
  sed -i '0,/^#include /s//#include <linux\/dma-buf.h>\n&/' fs/exec.c
  ok "已还原 exec.c 的 dma-buf.h"
fi

log "5/8 Unicode 绕过修复"
patch -p1 --forward < "$ACTION_BUILD/patches/unicode_bypass_fix_6.1+.patch" || warn "Unicode 补丁未应用"

# ---------------- LZ4 1.10.0 + ARM64 NEON ----------------
FEAT_LZ4_NEON="${FEAT_LZ4_NEON:-true}"
if [ "$FEAT_LZ4_NEON" = "true" ] && [ -d "$ZRAM_DIR" ]; then
  log "★ LZ4 1.10.0 升级 + ARM64 NEON 加速"
  cd "$COMMON"
  # 1) 升级 LZ4 到 1.10.0（带 armv8 NEON 解压）
  rm -f lib/lz4/lz4_compress.c lib/lz4/lz4_decompress.c lib/lz4/lz4defs.h lib/lz4/lz4hc_compress.c
  cp -r "$ZRAM_DIR/lz4/"* ./lib/lz4/
  cp -r "$ZRAM_DIR/include/linux/"* ./include/linux/
  ok "LZ4 已升级到 $(grep -oP 'LZ4_VERSION_MAJOR \K[0-9]+' lib/lz4/lz4.h).$(grep -oP 'LZ4_VERSION_MINOR \K[0-9]+' lib/lz4/lz4.h).$(grep -oP 'LZ4_VERSION_RELEASE \K[0-9]+' lib/lz4/lz4.h)"
  # 2) 把 NEON 条件编译接入各调用点
  bash "$ZRAM_DIR/apply_lz4_neon.sh" && ok "NEON 条件编译已接入" || warn "NEON 脚本返回非零"
  # 3) f2fs iostat（ZRAM 流程需要）
  if [ -f fs/f2fs/Makefile ] && ! grep -qF 'f2fs-\$(CONFIG_F2FS_IOSTAT) += iostat.o' fs/f2fs/Makefile; then
    echo 'f2fs-$(CONFIG_F2FS_IOSTAT) += iostat.o' >> fs/f2fs/Makefile
  fi
  cd "$COMMON"
fi

# ---------------- 性能补丁包 ----------------
# 开关：USE_PERF=true 集成 GKID 的 21 个性能补丁；false 则只保留 4 个新特性（=上一次的可用版本）
USE_PERF="${USE_PERF:-true}"
if [ "$USE_PERF" = "true" ] && [ -d "$PERF_DIR" ]; then
  log "★ 性能补丁包（$(ls "$PERF_DIR"/*.patch 2>/dev/null | wc -l) 个，来自 $PERF_DIR"
  cd "$COMMON"
  perf_ok=0; perf_fuzz=0; perf_fail=0
  for p in "$PERF_DIR"/*.patch; do
    pn=$(basename "$p")
    # 0003 与 Bypass 功能重复（都是放宽模块版本校验），跳过
    # 0004 的 lib/string 优化上游 6.12 已原生包含（BYTES_LONG/MIN_THRESHOLD 等宏
    #     在原始源码中就存在），fuzz 套用会造成 union types 重复定义，编译失败
    case "$pn" in
      0003-kernel-module.c-Force-loading*) echo "    - $pn (与 Bypass 重复，跳过)"; continue ;;
      0004-feat-lib-string-optimized-*)    echo "    - $pn (上游已含，跳过)"; continue ;;
    esac
    if git apply --check "$p" 2>/dev/null; then
      git apply "$p" && { echo "    ✓ $pn"; perf_ok=$((perf_ok+1)); }
    elif patch -p1 --fuzz=3 --batch --forward < "$p" >/dev/null 2>&1; then
      echo "    ~ $pn (fuzz)"; perf_fuzz=$((perf_fuzz+1))
    else
      echo "    ✗ $pn (失败)"; perf_fail=$((perf_fail+1))
    fi
  done
  find "$COMMON" -name "*.rej" -delete 2>/dev/null
  ok "性能补丁: 干净 $perf_ok / fuzz $perf_fuzz / 失败 $perf_fail"
  cd "$COMMON"
fi

# ---------------- 新特性 ----------------
if [ "$FEAT_BBRV3" = "true" ]; then
  log "★ BBRv3 补丁"
  if git apply --check "$BBRV3_PATCH" 2>/dev/null; then
    git apply "$BBRV3_PATCH" && ok "BBRv3 已应用"
  else
    patch -p1 --forward --fuzz=3 < "$BBRV3_PATCH" \
      && ok "BBRv3 已应用（带 fuzz）" || warn "BBRv3 应用失败，将使用内核自带 BBR"
  fi
fi

if [ "$FEAT_BBG" = "true" ]; then
  log "★ BBG 防格机"
  cd "$KERNEL_ROOT"
  # `curl ... | bash` 的退出码取自 bash，curl 失败会被掩盖（曾导致 Kconfig 引用不存在的目录）。
  # 改为先落盘、校验非空再执行；并清理可能残留的悬空软链，否则 setup.sh 会误判已安装。
  BBG_SETUP="$LOCAL_WORK/bbg_setup.sh"
  if [ -L "$KERNEL_ROOT/common/security/baseband-guard" ] && [ ! -d "$KERNEL_ROOT/common/security/baseband-guard/" ]; then
    warn "清理悬空的 baseband-guard 软链"
    rm -f "$KERNEL_ROOT/common/security/baseband-guard"
  fi
  rm -f "$BBG_SETUP"
  retry 4 10 bash -c "curl -LSs -o $BBG_SETUP 'https://ghfast.top/raw.githubusercontent.com/vc-teahouse/Baseband-guard/main/setup.sh' || curl -LSs -o $BBG_SETUP 'https://raw.githubusercontent.com/vc-teahouse/Baseband-guard/main/setup.sh'"
  [ -s "$BBG_SETUP" ] || die "BBG setup.sh 下载失败"
  bash "$BBG_SETUP" || die "BBG setup.sh 执行失败"
  [ -d "$KERNEL_ROOT/Baseband-guard" ] || die "BBG 仓库未就位（Baseband-guard 目录缺失）"
  ok "BBG 已安装"
fi

if [ "$FEAT_DROIDSPACES" = "true" ]; then
  log "★ Droidspaces 容器支持"
  cd "$COMMON"
  patch -p1 --forward < "$DROIDSPACES_PATCHES/kernel-6.12/001.GKI-6.12-or-above-fix_sysvipc_kabi.patch" \
    && ok "SYSVIPC kABI 补丁已应用" || warn "SYSVIPC kABI 补丁失败"
  # 6.12 rust_binder 引用 init_ipc_ns/put_ipc_ns，当前分支未导出，需补齐
  if [ -f ipc/msgutil.c ] && ! grep -qF 'EXPORT_SYMBOL(init_ipc_ns);' ipc/msgutil.c; then
    sed -i '/^struct msg_msgseg {/i EXPORT_SYMBOL(init_ipc_ns);' ipc/msgutil.c
  fi
  if [ -f ipc/namespace.c ] && ! grep -qF 'EXPORT_SYMBOL(put_ipc_ns);' ipc/namespace.c; then
    sed -i '/^static struct ns_common \*ipcns_get(/i EXPORT_SYMBOL(put_ipc_ns);' ipc/namespace.c
  fi
  ok "ipc 符号导出已补齐"
fi

if [ "$FEAT_NTSYNC" = "true" ]; then
  log "★ NTSync 启用"
  cd "$COMMON"
  # 优先用本地缓存（网络不稳时 raw.githubusercontent.com 常 TLS 失败），否则走镜像再走官方
  NTPATCH=ntsync_compat_android16-6.12.patch
  if [ -s "$LOCAL_CACHE/$NTPATCH" ]; then
    cp "$LOCAL_CACHE/$NTPATCH" "$NTPATCH"
    log "使用本地缓存的 NTSync 补丁"
  else
    retry 4 10 bash -c "curl -LSs -o '$NTPATCH' 'https://ghfast.top/raw.githubusercontent.com/Goldzxcbug/Droidspaces_Kernel_patch/refs/heads/main/NTsync/$NTPATCH' || curl -LSs -o '$NTPATCH' 'https://raw.githubusercontent.com/Goldzxcbug/Droidspaces_Kernel_patch/refs/heads/main/NTsync/$NTPATCH'"
  fi
  [ -s "$NTPATCH" ] || die "NTSync 补丁下载失败"
  # 上游 6.12 已自带 ntsync.c/ntsync.h，只打 compat 补丁（Kconfig depends on BROKEN -> default m）
  if [ -e drivers/misc/ntsync.c ] || [ -e include/uapi/linux/ntsync.h ]; then
    log "上游已含 NTSync，跳过 base 补丁"
  fi
  patch -p1 --forward < "$NTPATCH" && ok "NTSync compat 补丁已应用"
fi

log "6/8 配置内核"
cd "$KERNEL_ROOT"          # 以下路径均相对 KERNEL_ROOT
# --- 构建配置（build.config.gki*）---
sed -i 's/check_defconfig//' ./common/build.config.gki
sed -i 's/BUILD_SYSTEM_DLKM=1/BUILD_SYSTEM_DLKM=0/' ./common/build.config.gki.aarch64
sed -i '/MODULES_ORDER=android\/gki_aarch64_modules/d' ./common/build.config.gki.aarch64
sed -i '/KMI_SYMBOL_LIST_STRICT_MODE/d' ./common/build.config.gki.aarch64
# 清空 KMI 受保护符号名单（否则 rfkill/cfg80211 等加载失败）
sed -i '/"protected_exports_list"[[:space:]]*:[[:space:]]*"android\/abi_gki_protected_exports_aarch64",$/d' ./common/BUILD.bazel
sed -i '/protected_module_names_list = ":gki_aarch64_protected_module_names",/d' ./common/BUILD.bazel
rm -rf ./common/android/abi_gki_protected_exports_*
# 断电可能把文件截断成 0 字节；sed 对空文件不报错，会一路混到 Bazel 才炸。
# 修改前后都校验大小，且为空时直接从 git 恢复。
STAMP=./build/kernel/kleaf/impl/stamp.bzl
if [ ! -s "$STAMP" ]; then
  warn "$STAMP 为空（疑似断电截断），从 git 恢复"
  git -C ./build/kernel checkout -- kleaf/impl/stamp.bzl
fi
sed -i "/stable_scmversion_cmd/s/-maybe-dirty//g" "$STAMP"
[ -s "$STAMP" ] || die "$STAMP 修改后变为空，构建中止"
# BBRv3 的 bbr_param() 是编译期常量宏，`x && bbr_param(...)` 会触发
# -Wconstant-logical-operand；kleaf 用 -Werror 会直接失败，这里降级为非致命
python3 - <<'PYEOF'
import re, os
f = "common/BUILD.bazel"
s = open(f).read()
if "constant-logical-operand" not in s:
    old = "    kcflags = COMMON_KCFLAGS,\n    kmi_enforced = True,"
    new = ('    kcflags = list(COMMON_KCFLAGS) + [\n'
           '        "-Wno-error=constant-logical-operand",\n'
           '    ],\n'
           '    kmi_enforced = True,')
    assert s.count(old) >= 1, "未找到 kcflags 锚点"
    s = s.replace(old, new, 1)
    open(f, "w").write(s)
    print("已为 kernel_aarch64 追加 kcflags")
else:
    print("kcflags 已包含该选项，跳过")
PYEOF
ok "构建配置已调整"

# --- Bypass：模块版本校验放宽 ---
if grep -q 'bad_version:' ./common/kernel/module/version.c; then
  sed -i '/bad_version:/{:a;n;/return 0;/{s/return 0;/return 1;/;b};ba}' ./common/kernel/module/version.c
  sed -n '/bad_version:/,/return [01];/p' ./common/kernel/module/version.c | grep -q 'return 1;' \
    && ok "Bypass 模块版本校验绕过已启用" || die "Bypass 补丁失败"
fi

# --- BBG 的 LSM 链 ---
if [ "$FEAT_BBG" = "true" ]; then
  sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' ./common/security/Kconfig
  grep -q baseband_guard ./common/security/Kconfig && ok "LSM 链已加入 baseband_guard"
fi

# --- 版本串 ---
cd "$COMMON"
GHASH=$(git rev-parse --verify HEAD | cut -c1-13)
BID="ab$((RANDOM % 90000000 + 10000000))"
SUFFIX="-android16-5-g${GHASH}-${BID}"
perl -i -0777 -pe "s/(.*)echo \"\\\$\{KERNELVERSION\}\\\$\{file_localversion\}\\\$\{config_localversion\}\\\$\{LOCALVERSION\}\\\$\{scm_version\}\"/\$1echo \"\\\${KERNELVERSION}${SUFFIX}\\\$\{config_localversion\}\"/s" ./scripts/setlocalversion
export KBUILD_BUILD_TIMESTAMP="$(TZ='UTC' date +'%a %b %d %T %Z %Y')"
export KBUILD_BUILD_VERSION=1
if grep -q 'UTS_VERSION=' ./scripts/mkcompile_h; then
  perl -pi -e "s{UTS_VERSION=\"\\\$\\\(.*?\\\)(\s*)\"}{UTS_VERSION=\"\\\$1 SMP PREEMPT $KBUILD_BUILD_TIMESTAMP\"}" ./scripts/mkcompile_h
fi

# --- 生成 fragment ---
cd "$KERNEL_ROOT"
{
  echo "CONFIG_KSU=y"
  echo "CONFIG_TMPFS_XATTR=y"
  echo "CONFIG_TMPFS_POSIX_ACL=y"
  # SuSFS 全量
  cat <<'EOF'
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
EOF
  # 默认拥塞控制 BBR
  echo "CONFIG_TCP_CONG_BBR=y"
  echo "CONFIG_DEFAULT_BBR=y"
  [ "$FEAT_NTSYNC" = "true" ] && echo "CONFIG_NTSYNC=y"
  [ "$FEAT_BBG" = "true" ] && echo "CONFIG_BBG=y"
  # HZ=300 + ZRAM 三项（方案 B）
  if [ "$FEAT_TUNING" = "true" ]; then
    # 注意：ZRAM_DEF_COMP_* 是同一个 choice 组，只能选一个（这里选 LZ4）
    cat <<'EOF'
CONFIG_HZ_300=y
CONFIG_HZ=300
CONFIG_ZRAM_DEF_COMP_LZ4=y
CONFIG_ZRAM_WRITEBACK=y
CONFIG_ZRAM_MEMORY_TRACKING=y
EOF
  fi
  if [ "$FEAT_LZ4_NEON" = "true" ]; then
    echo "CONFIG_KERNEL_MODE_NEON=y"
  fi
  # A1 IP_SET 完整集合 / A2 IPv6 NAT / A3 杂项（netfilter 增强）
  if [ "$FEAT_NETFILTER" = "true" ]; then
    cat <<'EOF'
CONFIG_IP_SET_MAX=65534
CONFIG_IP_SET_BITMAP_IP=y
CONFIG_IP_SET_BITMAP_IPMAC=y
CONFIG_IP_SET_BITMAP_PORT=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_IPMARK=y
CONFIG_IP_SET_HASH_IPPORT=y
CONFIG_IP_SET_HASH_IPPORTIP=y
CONFIG_IP_SET_HASH_IPPORTNET=y
CONFIG_IP_SET_HASH_IPMAC=y
CONFIG_IP_SET_HASH_MAC=y
CONFIG_IP_SET_HASH_NETPORTNET=y
CONFIG_IP_SET_HASH_NETNET=y
CONFIG_IP_SET_HASH_NETPORT=y
CONFIG_IP_SET_HASH_NETIFACE=y
CONFIG_IP_SET_LIST_SET=y
CONFIG_IP6_NF_NAT=y
CONFIG_IP6_NF_TARGET_MASQUERADE=y
CONFIG_IP6_NF_TARGET_HL=y
CONFIG_IP6_NF_MATCH_HL=y
CONFIG_TCP_CONG_WESTWOOD=y
CONFIG_IP_NF_TARGET_TTL=y
EOF
  fi
  if [ "$FEAT_DROIDSPACES" = "true" ]; then
    cat <<'EOF'
CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y
CONFIG_IPC_NS=y
CONFIG_PID_NS=y
CONFIG_DEVTMPFS=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_NETFILTER_XT_MATCH_RECENT=y
CONFIG_IP_SET=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_NETFILTER_XT_SET=y
CONFIG_NETFILTER_XT_TARGET_REJECT=y
CONFIG_IP_NF_TARGET_REJECT=y
EOF
  fi
} > "$FRAG"
cp "$DEFCONFIG.orig" "$DEFCONFIG"
# 过滤掉内核 Kconfig 中不存在的符号（不同版本符号名会变，如 6.12 已无
# NETFILTER_XT_TARGET_REJECT）。kleaf 的 trim 校验会因无效符号直接失败。
filter_valid_symbols() {
  local frag="$1" tmp="$frag.tmp" dropped=0 sym
  : > "$tmp"
  while IFS= read -r line; do
    case "$line" in
      CONFIG_*=*)
        sym="${line%%=*}"
        sym="${sym#CONFIG_}"
        if grep -RqsE --include='Kconfig*' "^[[:space:]]*(menuconfig|config)[[:space:]]+${sym}$" "$COMMON" 2>/dev/null; then
          echo "$line" >> "$tmp"
        else
          warn "内核未定义 $sym，已从 fragment 移除"
          dropped=$((dropped+1))
        fi
        ;;
      *) echo "$line" >> "$tmp" ;;
    esac
  done < "$frag"
  mv "$tmp" "$frag"
  [ $dropped -eq 0 ] && ok "fragment 符号全部有效" || warn "已移除 $dropped 个无效符号"
}
filter_valid_symbols "$FRAG"
ok "fragment 已生成（$(wc -l < "$FRAG") 项）"
cat "$FRAG" | sed 's/^/    /'


export PATH="$ROOT/prebuilts/build-tools/linux-x86:$KERNEL_ROOT:$PATH"
FRAG_FLAG="--defconfig_fragment=//common:arch/arm64/configs/ksu.fragment"
# LTO：默认 none（已验证开机）。fullLTO 为实验选项——
# kleaf 支持 --lto=full，但项目对 6.12 强制 lto=none（注释称 rust_binder 不兼容 thin LTO），
# full LTO 对 Rust 模块的兼容性同样未经验证，且 GKID 内核不开机的头号嫌疑就是 fullLTO。
# 改动只影响实验包，基线 release/baseline/LATEST-GOOD-*.zip 不受影响。
LTO_MODE="${LTO_MODE:-none}"
BUILD_METHOD="${BUILD_METHOD:-bazel}"     # bazel(默认，唯一可用) | make(仅对照实验)
METHOD_TAG=""
MAKE_OUT="$KERNEL_ROOT/out"

build_with_bazel() {
  log "7/8 Bazel 构建 (lto=$LTO_MODE)"
  export PATH="$ROOT/prebuilts/build-tools/linux-x86:$KERNEL_ROOT:$PATH"
  FRAG_FLAG="--defconfig_fragment=//common:arch/arm64/configs/ksu.fragment"
  # LTO：kleaf 架构下 6.12 一开 LTO 就因 rust_binder 产出路径失败（thin/full 均实测失败），
  # 故默认 none。6.1/6.6 可用 thin（无 rust_binder）。
  case "$LTO_MODE" in
    none) : ;;
    thin|full) warn "实验模式：--lto=$LTO_MODE（6.12 下已知会因 rust_binder 失败）" ;;
    *) die "未知 LTO_MODE=$LTO_MODE（可选 none/thin/full）" ;;
  esac
  "$KERNEL_ROOT/tools/bazel" build --disk_cache="$HOME/.cache/bazel" --config=fast --lto="$LTO_MODE" $FRAG_FLAG \
    //common:kernel_aarch64_dist || die "Bazel 构建失败"
  SRC="$KERNEL_ROOT/bazel-bin/common/kernel_aarch64"
}

build_with_make() {
  # 传统 kbuild 流程（类 GKID）：模块由 modpost 独立链接，rust_binder 不参与 vmlinux 的
  # LTO 单元，因此可以开 fullLTO。编译器仍用 manifest 自带的 AOSP clang。
  log "7/8 make/kbuild 构建 (lto=$LTO_MODE)"
  K="$KERNEL_ROOT"
  local CLANG_VER RUST_VER
  CLANG_VER=$(grep -oP 'CLANG_VERSION=\K.*' "$COMMON/build.config.constants" 2>/dev/null)
  RUST_VER=$(grep -oP 'RUSTC_VERSION=\K.*' "$COMMON/build.config.constants" 2>/dev/null)
  [ -d "$K/prebuilts/clang/host/linux-x86/clang-$CLANG_VER/bin" ] || die "找不到 clang-$CLANG_VER"
  [ -d "$K/prebuilts/rust/linux-x86/$RUST_VER/bin" ] || die "找不到 rustc $RUST_VER"

  export PATH="$K/prebuilts/clang/host/linux-x86/clang-$CLANG_VER/bin:$K/prebuilts/rust/linux-x86/$RUST_VER/bin:$K/prebuilts/build-tools/linux-x86/bin:$K/prebuilts/kernel-build-tools/linux-x86/bin:$K/prebuilts/clang-tools/linux-x86/bin:$HOME/.local/bin:$PATH"
  log "clang: $(clang --version | head -1)"
  log "rustc: $(rustc --version 2>/dev/null | head -1)"

  export ARCH=arm64 LLVM=1 LLVM_IAS=1
  export CROSS_COMPILE=aarch64-linux-gnu-
  export CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
  export CC="ccache clang" CXX="ccache clang++"
  export LD=ld.lld NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump
  export AR=llvm-ar RANLIB=llvm-ranlib STRIP=llvm-strip READELF=llvm-readelf
  export HOSTCC=clang HOSTCXX=clang++ HOSTLD=ld.lld
  export KCFLAGS="-D__ANDROID_COMMON_KERNEL__ -Wno-error=constant-logical-operand"
  export KBUILD_BUILD_TIMESTAMP KBUILD_BUILD_VERSION=1

  # fragment 直接并入 defconfig（make 路径没有 --defconfig_fragment）
  cp "$DEFCONFIG.orig" "$DEFCONFIG"
  if [ -s "$FRAG" ]; then
    log "并入 fragment（$(wc -l < "$FRAG") 项）到 gki_defconfig"
    cat "$FRAG" >> "$DEFCONFIG"
  fi

  if [ "$LTO_MODE" = "full" ]; then
    log "追加 CONFIG_LTO_CLANG_FULL"
    printf 'CONFIG_LTO=y\nCONFIG_LTO_CLANG=y\n# CONFIG_LTO_NONE is not set\nCONFIG_LTO_CLANG_FULL=y\n# CONFIG_LTO_CLANG_THIN is not set\n' >> "$DEFCONFIG"
  elif [ "$LTO_MODE" = "thin" ]; then
    printf 'CONFIG_LTO=y\nCONFIG_LTO_CLANG=y\n# CONFIG_LTO_NONE is not set\n# CONFIG_LTO_CLANG_FULL is not set\nCONFIG_LTO_CLANG_THIN=y\n' >> "$DEFCONFIG"
  else
    printf '# CONFIG_LTO is not set\n' >> "$DEFCONFIG"
  fi

  log "make gki_defconfig"
  make -C "$COMMON" O="$MAKE_OUT" gki_defconfig >/dev/null || die "make gki_defconfig 失败"
  grep -E "^CONFIG_LTO" "$MAKE_OUT/.config" | sed 's/^/    /'

  log "make -j$(nproc)（fullLTO 链接较慢，耐心等待）"
  make -C "$COMMON" O="$MAKE_OUT" -j"$(nproc --all)" || die "make 构建失败"
  SRC="$MAKE_OUT/arch/arm64/boot"
}

case "$BUILD_METHOD" in
  bazel) build_with_bazel ;;
  make)  METHOD_TAG="-MAKE"; build_with_make ;;
  *) die "未知 BUILD_METHOD=$BUILD_METHOD（可选 bazel/make）" ;;
esac

[ -f "$SRC/Image" ] || die "未找到 Image（$SRC/Image）"
cp "$SRC/Image" "$ROOT/Bypass-Image"
strings "$ROOT/Bypass-Image" | grep -m1 'Linux version'

log "8/8 打包"
CONFIG_TAG="$ANDROID_VERSION-$KERNEL_VERSION.$SUBLEVEL-$OS_PATCH_LEVEL"
LTO_TAG=""; [ "$LTO_MODE" != "none" ] && LTO_TAG="-LTO$(echo $LTO_MODE | tr a-z A-Z)"
ZIP="$ROOT/${CONFIG_TAG}${METHOD_TAG}${LTO_TAG}-ReSukiSU-Bypass-AnyKernel3.zip"
cd "$ANYKERNEL3"
rm -f Image Bypass-Image *.orig *.rej tools/*.orig tools/*.rej
cp "$ROOT/Bypass-Image" ./Image
zip -r "$ZIP" ./* >/dev/null
ok "已生成: $ZIP"
ls -la "$ZIP"
echo "FEATURE_BUILD_DONE zip=$ZIP sublevel=$SUBLEVEL"
