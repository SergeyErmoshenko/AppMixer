#!/bin/zsh
# Локальная подпись без Apple ID, полностью без диалогов.
#
# Использует ОТДЕЛЬНУЮ связку ключей со случайным паролем (хранится в
# .signing-secret рядом со скриптом) — не зависит от пароля учётки,
# корпоративных смен пароля и старого пароля связки login. Разрешение
# codesign на использование ключа выдаётся заранее (set-key-partition-list),
# поэтому GUI-запросов «Always Allow» тоже не будет.
#
# Даёт стабильную «личность» приложения: TCC привязывает разрешение на
# запись системного звука к сертификату и перестаёт переспрашивать после
# пересборок. Один запуск настраивает всё, живёт 10 лет, офлайн.
set -euo pipefail

IDENTITY="AppMixer Dev"
APP="build/Build/Products/Release/AppMixer.app"
KC="$HOME/Library/Keychains/appmixer-signing.keychain-db"
SECRET_FILE="$(dirname "$0")/../.signing-secret"
cd "$(dirname "$0")/.."

# 0. Случайный секрет связки (создаётся один раз, права 600, в .gitignore).
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
    # Автоблокировка через сутки; скрипт всё равно разблокирует при каждом запуске.
    security set-keychain-settings -t 86400 "$KC"
fi
security unlock-keychain -p "$KC_PASS" "$KC"

# 2. Сертификат подписи (один раз). Пароль p12 случайный и живёт одну строку —
#    security import получает его явно, GUI ничего не спрашивает.
if ! security find-identity -v -p codesigning "$KC" | grep -q "$IDENTITY"; then
    echo "→ Создаю сертификат «$IDENTITY»…"
    WORK="$(mktemp -d)"
    P12_PASS="$(openssl rand -hex 16)"
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
        -x509 -days 3650 -out "$WORK/cert.pem" -config "$WORK/openssl.cnf" 2>/dev/null
    openssl pkcs12 -export -in "$WORK/cert.pem" -inkey "$WORK/key.pem" \
        -out "$WORK/cert.p12" -name "$IDENTITY" -passout pass:"$P12_PASS"
    security import "$WORK/cert.p12" -k "$KC" -P "$P12_PASS" -T /usr/bin/codesign
    # Эквивалент «Always Allow» для codesign — заранее, без диалогов.
    security set-key-partition-list -S apple-tool:,apple: -k "$KC_PASS" "$KC" >/dev/null
    rm -rf "$WORK"
    echo "✓ Сертификат в связке ${KC:t}."
fi

# 3. Сборка Release (без Apple-подписи — подпишем сами).
XCODEGEN="$( [[ -x .tools/xcodegen/bin/xcodegen ]] && echo .tools/xcodegen/bin/xcodegen || echo xcodegen )"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
"$XCODEGEN" generate
xcodebuild -project AppMixer.xcodeproj -scheme AppMixer -configuration Release \
    CODE_SIGNING_ALLOWED=NO -derivedDataPath build build \
    | grep -E "^\*\* BUILD" || true

# 4. Подпись стабильной личностью — молча.
codesign --force --keychain "$KC" --sign "$IDENTITY" "$APP"
echo "✓ Подписано:"
codesign -dv "$APP" 2>&1 | grep -E "Identifier=|Signature=|TeamIdentifier"

echo
echo "Установка (выполните):"
echo "  osascript -e 'quit app \"AppMixer\"' 2>/dev/null; rm -rf /Applications/AppMixer.app"
echo "  ditto $APP /Applications/AppMixer.app && open /Applications/AppMixer.app"
echo
echo "Первый запуск новой подписи спросит разрешение на звук ОДИН последний раз."
