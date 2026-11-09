#!/bin/zsh
# Локальная подпись без Apple ID.
#
# Самоподписанный сертификат даёт приложению стабильную «личность»: TCC
# привязывает разрешение на запись системного звука к сертификату и не
# переспрашивает после пересборок. Связка — отдельная, со случайным паролем
# (.signing-secret), пароли учётки и старые пароли login-связки не нужны.
#
# КРИТИЧНО: p12 собирается СИСТЕМНЫМ openssl (/usr/bin/openssl, LibreSSL).
# Homebrew OpenSSL 3 экспортирует p12 в формате, который macOS 26 молча
# не спаривает с ключом («1 identity imported», но 0 valid identities).
set -euo pipefail

IDENTITY="AppMixer Dev"
APP="build/Build/Products/Release/AppMixer.app"
KC="$HOME/Library/Keychains/appmixer-signing.keychain-db"
SECRET_FILE="$(dirname "$0")/../.signing-secret"
cd "$(dirname "$0")/.."

OPENSSL="/usr/bin/openssl"
[[ -x "$OPENSSL" ]] || OPENSSL="$(command -v openssl)"

# 0. Случайный секрет связки (один раз, права 600, в .gitignore).
if [[ -f "$SECRET_FILE" ]]; then
    KC_PASS="$(<"$SECRET_FILE")"
else
    KC_PASS="$(openssl rand -hex 24)"
    (umask 077; print -r -- "$KC_PASS" > "$SECRET_FILE")
    echo "→ Секрет новой связки сохранён в ${SECRET_FILE:t}"
fi

# 1. Отдельная связка ключей (один раз) + разблокировка.
if ! security show-keychain-info "$KC" &>/dev/null; then
    echo "→ Создаю связку ключей ${KC:t}…"
    security create-keychain -p "$KC_PASS" "$KC"
    security set-keychain-settings -t 86400 "$KC"
fi
security unlock-keychain -p "$KC_PASS" "$KC"

# 2. Связка в поисковом списке — иначе codesign «no identity found».
if ! security list-keychains | grep -q "$KC"; then
    echo "→ Добавляю связку в поисковый список…"
    security list-keychains -s $(security list-keychains | tr -d '"' | tr '\n' ' ') "$KC"
fi

have_identity() {
    security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"
}

# 3. Сертификат, если его ещё нет.
if ! have_identity; then
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
    P12_PASS="$(openssl rand -hex 16)"
    "$OPENSSL" pkcs12 -export -in "$WORK/cert.pem" -inkey "$WORK/key.pem" \
        -out "$WORK/cert.p12" -name "$IDENTITY" -passout pass:"$P12_PASS"
    security import "$WORK/cert.p12" -k "$KC" -P "$P12_PASS" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple: -k "$KC_PASS" "$KC" >/dev/null
    rm -rf "$WORK"
fi

# 4. Идентичность обязана появиться; иначе — диагностика и стоп.
if ! have_identity; then
    echo
    echo "✗ Идентичность «$IDENTITY» не сформировалась. Диагностика:"
    echo "--- identity (политика codesigning):"
    security find-identity -v -p codesigning || true
    echo "--- identity (без политики):"
    security find-identity -v || true
    echo "--- сертификат в связке:"
    security find-certificate -c "$IDENTITY" "$KC" >/dev/null 2>&1 \
        && echo "сертификат на месте" || echo "СЕРТИФИКАТА НЕТ"
    exit 1
fi
echo "✓ Идентичность «$IDENTITY» готова."

# 5. Сборка Release (без Apple-подписи — подпишем сами).
XCODEGEN="$( [[ -x .tools/xcodegen/bin/xcodegen ]] && echo .tools/xcodegen/bin/xcodegen || echo xcodegen )"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
"$XCODEGEN" generate
xcodebuild -project AppMixer.xcodeproj -scheme AppMixer -configuration Release \
    CODE_SIGNING_ALLOWED=NO -derivedDataPath build build \
    | grep -E "^\*\* BUILD" || true

# 6. Подпись (молча).
codesign --force --sign "$IDENTITY" "$APP"
echo "✓ Подписано:"
codesign -dv "$APP" 2>&1 | grep -E "Identifier=|Signature=|TeamIdentifier"

echo
echo "Установка (выполните):"
echo "  osascript -e 'quit app \"AppMixer\"' 2>/dev/null; rm -rf /Applications/AppMixer.app"
echo "  ditto $APP /Applications/AppMixer.app && open /Applications/AppMixer.app"
echo
echo "Первый запуск новой подписи спросит разрешение на звук ОДИН последний раз."
