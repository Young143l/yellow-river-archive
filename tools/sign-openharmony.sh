#!/usr/bin/env bash
#
# 给 OpenHarmony HAP 签名。
#
# 为什么不用 hvigor 的 signingConfig：它要求 storePassword / keyPassword 是
# DevEco 加密后的 32 位密文，命令行生成不出来。所以拆成两步 ——
# hvigor 只负责产出 unsigned HAP，本脚本用 SDK 自带的 hap-sign-tool 签名。
#
# 证书来源：OpenHarmony SDK 自带的官方测试证书链
#   <SDK>/toolchains/lib/OpenHarmony.p12     口令 123456
#   <SDK>/toolchains/lib/UnsgnedReleasedProfileTemplate.json
# 这是 OpenHarmony 官方公开的测试材料，不是私密凭据。
#
# 用法：
#   tools/sign-openharmony.sh            # 构建 + 签名
#   tools/sign-openharmony.sh --sign-only # 只签已存在的 unsigned HAP

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/harmony/YellowRiverArchive"
SIGN="$APP/signature"
OUT="$APP/entry/build/default/outputs/default"
SDK="${OHOS_SDK:-$HOME/Library/OpenHarmony/Sdk/26.0.0}"
LIB="$SDK/toolchains/lib"
KING="$LIB/hap-sign-tool.jar"

[ -f "$KING" ] || { echo "找不到 hap-sign-tool.jar：$KING"; echo "用 OHOS_SDK 指定 SDK 路径"; exit 1; }

if [ "${1:-}" != "--sign-only" ]; then
  echo "== 1/3 构建 unsigned HAP =="
  (cd "$APP" && devecocli build)
fi

echo "== 2/3 签 profile =="
java -jar "$KING" sign-profile \
  -keyAlias "openharmony application profile release" \
  -signAlg SHA256withECDSA -mode localSign \
  -profileCertFile "$LIB/OpenHarmonyProfileRelease.pem" \
  -inFile "$SIGN/profile.json" \
  -keystoreFile "$LIB/OpenHarmony.p12" \
  -outFile "$SIGN/yellowriver.p7b" \
  -keyPwd 123456 -keystorePwd 123456

echo "== 3/3 签 HAP =="
java -jar "$KING" sign-app \
  -keyAlias "openharmony application release" \
  -signAlg SHA256withECDSA -mode localSign \
  -appCertFile "$SIGN/yellowriver.cer" \
  -profileFile "$SIGN/yellowriver.p7b" \
  -inFile "$OUT/entry-default-unsigned.hap" \
  -keystoreFile "$LIB/OpenHarmony.p12" \
  -outFile "$OUT/entry-default-signed.hap" \
  -keyPwd 123456 -keystorePwd 123456

echo "== 校验 =="
java -jar "$KING" verify-app -inFile "$OUT/entry-default-signed.hap" \
  -outCertChain /tmp/verify.cer -outProfile /tmp/verify.p7b 2>&1 | grep -i "verify"
ls -lh "$OUT/entry-default-signed.hap" | awk '{print "产物:", $9, $5}'
