#!/usr/bin/env bash
# 把构建好的刷机包推送到手机，并删除同名的旧包
#
#   ADB=/path/to/adb scripts/push_to_phone.sh <zip路径> [旧包名]
set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=local-env.sh
source "$SCRIPT_DIR/local-env.sh"

ADB="${ADB:-adb}"
NEW_ZIP="${1:?用法: push_to_phone.sh <zip路径> [旧包名]}"
DEST="${DEST:-/sdcard}"
OLD_NAME="${2:-$(basename "$NEW_ZIP")}"

[ -f "$NEW_ZIP" ] || die "找不到新包: $NEW_ZIP"

SERIAL="$($ADB devices | awk '$2=="device"{print $1; exit}')"
[ -n "$SERIAL" ] || die "没有已连接的设备（$ADB devices）"
ADB="$ADB -s $SERIAL"

log "推送到 $SERIAL:$DEST/"
$ADB push "$NEW_ZIP" "$DEST/" | tail -1

if [ "$OLD_NAME" != "$(basename "$NEW_ZIP")" ]; then
  log "删除旧包 $DEST/$OLD_NAME"
  $ADB shell "rm -f '$DEST/$OLD_NAME'" >/dev/null
fi

log "手机现有 zip："
$ADB shell "ls -la $DEST/*.zip"
log "校验和对比："
$ADB shell "sha256sum '$DEST/$(basename "$NEW_ZIP")'"
sha256sum "$NEW_ZIP"
echo "PUSH_DONE"
