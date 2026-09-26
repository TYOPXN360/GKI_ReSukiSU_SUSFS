# 本地构建（无需 GitHub Actions）

除了 CI，本仓库还提供一套完整的**本地构建脚本**，用于调试、定制或离线出包。

## 快速开始

```bash
# 1. 同步内核源码（首次，约 30 分钟 / 27GB）
scripts/recover_sync.sh

# 2. 构建（默认全特性 + Bazel + lto=none）
scripts/build_local.sh

# 产物
.local-build/android16-6.12.93-dev-ReSukiSU-Bypass-AnyKernel3.zip
```

## 脚本一览

| 脚本 | 作用 |
|---|---|
| `scripts/recover_sync.sh` | 同步 AOSP manifest 源码；`FORCE=1` 强制重拉（断电/git 损坏后用） |
| `scripts/upgrade_kernel.sh` | 升级到谷歌官方最新 dev tip（`BRANCH=common-android16-6.12-lts` 可换 LTS） |
| `scripts/reset_tree.sh` | 把源码树重置回纯净上游状态 |
| `scripts/build_local.sh` | 打补丁 → 配置 → 编译 → 打包 |
| `scripts/push_to_phone.sh` | 推包到手机并删旧包 |
| `scripts/local-env.sh` | 公共配置（路径/工具链/代理），被上面各脚本 source |

## 特性开关

全部通过环境变量控制，默认全开：

```bash
FEAT_BBRV3=false        scripts/build_local.sh   # BBRv3
FEAT_NTSYNC=false       scripts/build_local.sh   # NTSync 解禁
FEAT_BBG=false          scripts/build_local.sh   # BBG 防格机
FEAT_DROIDSPACES=false  scripts/build_local.sh   # Droidspaces 容器
FEAT_LZ4_NEON=false     scripts/build_local.sh   # LZ4 1.10.0 + ARM64 NEON
FEAT_TUNING=false       scripts/build_local.sh   # HZ=300 + ZRAM
FEAT_NETFILTER=false    scripts/build_local.sh   # IP_SET 完整集 + IPv6 NAT + WESTWOOD/TTL
USE_PERF=false          scripts/build_local.sh   # GKID 性能补丁包
```

## ⚠️ 关于 LTO：6.12 上不要开启

经 5 组对照实测（编译器固定 AOSP clang 19.0.1，补丁集相同）：

| 构建 | LTO | 结果 |
|---|---|---|
| Bazel/kleaf | `none` | ✅ 开机正常 |
| make/kbuild | `none` | ✅ 开机正常 |
| make/kbuild | `thin` | ❌ **不开机** |
| make/kbuild | `full` | ❌ **不开机** |

**thin 和 full LTO 都会让 6.12 内核无法启动，且与编译器无关。**

因此 `BUILD_METHOD=bazel` + `LTO_MODE=none` 是唯一可用组合，也是默认值。
`build_local.sh` 仍保留 `BUILD_METHOD=make` 供对照实验，但请勿用于出包。

## 相对 CI 流程的额外适配

以下修复仅存在于本地脚本（CI 尚未包含），都是实测踩出来的：

1. **清空 KMI 受保护符号名单** — 公开 AOSP 树不含 `certs/signing_key.pem`，无法验证 Google 签名的 GKI 模块，导致 `mod->sig_ok=false`，`CONFIG_MODULE_SIG_PROTECT` 拒绝 `rfkill` 等模块导出受保护符号 → **WiFi / 相机 / 手电筒全部失效**。修复：移除 `BUILD.bazel` 中 `protected_module_names_list` 引用。
2. **`fs/exec.c` 的 `dma-buf.h` include 还原** — SuSFS 补丁会临时删掉该 include，打完必须加回，否则编译失败。
3. **fragment 符号有效性过滤** — 6.12 已移除 `NETFILTER_XT_TARGET_REJECT` 等符号，写进 defconfig 会被 kleaf trim 校验拒绝。
4. **`-Wno-error=constant-logical-operand`** — BBRv3 的 `bbr_param()` 是编译期常量宏，kleaf 用 `-Werror` 会致命。
5. **跳过 `0004` lib/string 补丁** — 该优化上游 6.12 已原生包含，fuzz 套用会造成 `union types` 重复定义。
6. **`ZRAM_DEF_COMP_LZ4HC` 不与 `LZ4` 并存** — 二者同属一个 `choice` 组。
7. **ReSukiSU 走 tarball 而非 git clone** — 代理下 `git clone` 传大 pack 会被截断。
8. **`file size` 护栏** — 断电可能把文件截断成 0 字节而 `sed` 不报错，脚本在关键修改前后校验非空。

## 依赖

```bash
# 有 root 时
sudo apt-get install -y cmake ccache python3 git curl build-essential \
  libssl-dev bison flex libelf-dev libdw-dev zlib1g-dev dwarves cpio zstd

# 无 root 时把工具解包到 .local-build/tools/（见下）
#   cmake: 官方二进制 tarball
#   zstd/cpio/pkgconf/libdw 等: apt-get download + dpkg -x
```

`build_local.sh` 不依赖 root，但需要 `cmake`（构建 pahole 用）和 `zstd`（解 antman/仓库包用）。
