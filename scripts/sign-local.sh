#!/bin/zsh
# Локальная подпись без Apple ID: самоподписанный сертификат в связке ключей
# + codesign. Даёт стабильную «личность» приложения — TCC привяжет разрешение
# на запись системного звука к сертификату и перестанет переспрашивать после
# каждой пересборки. Создаётся один раз, живёт 10 лет, Apple-серверы не нужны.
set -euo pipefail

IDENTITY="AppMixer Dev"
APP="build/Build/Products/Release/AppMixer.app"
cd "$(dirname "$0")/.."

# 1. Сертификата ещё нет — создаём и импортируем (однократно).
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "→ Создаю самоподписанный сертификат «$IDENTITY» (один раз)…"
    WORK="$(mktemp -d)"
    cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=$IDENTITY
[v3]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=codeSigning
EOF
    openssl req -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" \
        -x509 -days 3650 -out "$WORK/cert.pem" -config "$WORK/openssl.cnf"
    openssl pkcs12 -export -in "$WORK/cert.pem" -inkey "$WORK/key.pem" \
        -out "$WORK/cert.p12" -name "$IDENTITY" -passout pass:
    security import "$WORK/cert.p12" \
        -k "$HOME/Library/Keychains/login.keychain-db" \
        -T /usr/bin/codesign
    rm -rf "$WORK"
    echo "✓ Сертификат в связке ключей."
fi

# 2. Сборка Release без Apple-подписи (подпишем сами на шаге 3).
XCODEGEN="$( [ -x .tools/xcodegen/bin/xcodegen ] && echo .tools/xcodegen/bin/xcodegen || echo xcodegen )"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
"$XCODEGEN" generate
xcodebuild -project AppMixer.xcodeproj -scheme AppMixer -configuration Release \
    CODE_SIGNING_ALLOWED=NO -derivedDataPath build build \
    | grep -E "error:|BUILD" || true

# 3. Подпись стабильной личностью.
codesign --force --sign "$IDENTITY" "$APP"
echo "✓ Подписано:"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier"

echo
echo "Установка:"
echo "  osascript -e 'quit app \"AppMixer\"' 2>/dev/null; rm -rf /Applications/AppMixer.app"
echo "  ditto $APP /Applications/AppMixer.app && open /Applications/AppMixer.app"
