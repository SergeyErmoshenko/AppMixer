#!/bin/zsh
# Локальная подпись без Apple ID.
#
# Самоподписанный сертификат даёт приложению стабильную «личность»: TCC
# привязывает разрешение на запись системного звука к сертификату и не
# переспрашивает после пересборок.
#
# Почему именно так:
# - p12 собирается СИСТЕМНЫМ openssl (LibreSSL) — формат p12 от Homebrew
#   OpenSSL 3 macOS 26 молча не спаривает с ключом;
# - импорт идёт в LOGIN-связку (она уже разблокирована — пароля не нужно):
#   в кастомные связки из `security create-keychain` macOS 26 ключи
#   не импортирует (сертификат ложится, ключ нет — идентичность не
#   формируется); `-T codesign` навсегда разрешает codesign доступ к
#   ключу, поэтому никаких запросов «Always Allow» не будет.
set -euo pipefail

IDENTITY="AppMixer Dev"
APP="build/Build/Products/Release/AppMixer.app"
SECRET_FILE="$(dirname "$0")/../.signing-secret"
cd "$(dirname "$0")/.."

OPENSSL="/usr/bin/openssl"
[[ -x "$OPENSSL" ]] || OPENSSL="$(command -v openssl)"

# 0. Случайный пароль p12 (живёт одну строку, в связку попадает уже открытым).
P12_PASS="$(openssl rand -hex 16)"

# 1. Сертификат, если его ещё нет.
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "→ Создаю сертификат «$IDENTITY» ($("$OPENSSL" version | head -1))…"
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
    "$OPENSSL" req -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" \
        -x509 -days 3650 -out "$WORK/cert.pem" -config "$WORK/openssl.cnf" 2>/dev/null
    "$OPENSSL" pkcs12 -export -in "$WORK/cert.pem" -inkey "$WORK/key.pem" \
        -out "$WORK/cert.p12" -name "$IDENTITY" -passout pass:"$P12_PASS"
    security import "$WORK/cert.p12" -P "$P12_PASS" -T /usr/bin/codesign
    rm -rf "$WORK"
fi

# 2. Идентичность обязана появиться; иначе — диагностика и стоп.
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo
    echo "✗ Идентичность «$IDENTITY» не сформировалась. Диагностика:"
    echo "--- identity (политика codesigning):"
    security find-identity -v -p codesigning || true
    echo "--- identity (без политики):"
    security find-identity -v || true
    echo "--- сертификат:"
    security find-certificate -c "$IDENTITY" -Z 2>&1 | grep -E "SHA-1|\"labl\"|security:" || true
    exit 1
fi
echo "✓ Идентичность «$IDENTITY» готова."

# 3. Сборка Release (без Apple-подписи — подпишем сами).
XCODEGEN="$( [[ -x .tools/xcodegen/bin/xcodegen ]] && echo .tools/xcodegen/bin/xcodegen || echo xcodegen )"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
"$XCODEGEN" generate
xcodebuild -project AppMixer.xcodeproj -scheme AppMixer -configuration Release \
    CODE_SIGNING_ALLOWED=NO -derivedDataPath build build \
    | grep -E "^\*\* BUILD" || true

# 4. Подпись (молча).
codesign --force --sign "$IDENTITY" "$APP"
echo "✓ Подписано:"
codesign -dv "$APP" 2>&1 | grep -E "Identifier=|Signature=|TeamIdentifier"

echo
echo "Установка (выполните):"
echo "  osascript -e 'quit app \"AppMixer\"' 2>/dev/null; rm -rf /Applications/AppMixer.app"
echo "  ditto $APP /Applications/AppMixer.app && open /Applications/AppMixer.app"
echo
echo "Первый запуск новой подписи спросит разрешение на звук ОДИН последний раз."
