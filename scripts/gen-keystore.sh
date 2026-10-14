#!/usr/bin/env bash
# 生成 IMChat Android 发布签名密钥，并输出 GitHub Actions 所需的 secrets。
# 用法：ALIAS=imchat STORE_PASSWORD=xxx KEY_PASSWORD=xxx ./scripts/gen-keystore.sh
set -euo pipefail

KEYSTORE="${KEYSTORE:-imchat-release.jks}"
ALIAS="${ALIAS:-imchat}"

if ! command -v keytool >/dev/null 2>&1; then
  echo "错误：未找到 keytool，请先安装 JDK（例如 Temurin 17）。" >&2
  exit 1
fi

if [ -e "$KEYSTORE" ]; then
  echo "错误：$KEYSTORE 已存在，为避免覆盖已有密钥，已中止。" >&2
  exit 1
fi

if [ -z "${STORE_PASSWORD:-}" ]; then
  read -r -s -p "Keystore 密码（至少 6 位）: " STORE_PASSWORD; echo
  read -r -s -p "再次输入 Keystore 密码: " STORE_PASSWORD2; echo
  if [ "$STORE_PASSWORD" != "$STORE_PASSWORD2" ]; then
    echo "错误：两次输入的密码不一致。" >&2
    exit 1
  fi
fi

if [ -z "${KEY_PASSWORD:-}" ]; then
  read -r -s -p "Key 密码（直接回车则与 Keystore 密码相同）: " KEY_PASSWORD; echo
  KEY_PASSWORD="${KEY_PASSWORD:-$STORE_PASSWORD}"
fi

keytool -genkeypair \
  -keystore "$KEYSTORE" \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -storepass "$STORE_PASSWORD" \
  -keypass "$KEY_PASSWORD" \
  -dname "CN=IMChat"

if B64="$(base64 -w0 "$KEYSTORE" 2>/dev/null)"; then
  :
else
  B64="$(base64 < "$KEYSTORE" | tr -d '\n')"
fi

cat <<MSG

已生成：$KEYSTORE

请在 GitHub 仓库 Settings → Secrets and variables → Actions → New repository secret
中添加以下 4 个 secrets：

  ANDROID_KEYSTORE_BASE64   = （下方整段 base64）
  ANDROID_KEYSTORE_PASSWORD = 你刚才输入的 Keystore 密码
  ANDROID_KEY_ALIAS         = $ALIAS
  ANDROID_KEY_PASSWORD      = 你刚才输入的 Key 密码

----- ANDROID_KEYSTORE_BASE64 开始 -----
$B64
----- ANDROID_KEYSTORE_BASE64 结束 -----

⚠️  请务必妥善备份 $KEYSTORE 及其密码！
    一旦丢失，将无法再为已安装的应用发布升级版本（只能卸载重装）。
    切勿将 $KEYSTORE 提交到 Git 仓库。
MSG
