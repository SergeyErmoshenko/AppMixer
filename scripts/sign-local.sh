#!/bin/zsh
# Локальная подпись без Apple ID и без Связки ключей.
#
# rcodesign (indygreg/apple-platform-rs) подписывает bundle файлами
# сертификата и ключа напрямую. Это план Б, проверенный жизнью: macOS 26
# не импортирует закрытые ключи через `security import` ни в login-, ни в
# кастомные связки (сертификаты кладёт, ключи молча выбрасывает), поэтому
# классический путь через кодсигн-идентичность на этой системе не работает.
# rcodesign ставит ту же стандартную кодовую подпись — TCC привязывает
# разрешение на запись системного звука к сертификату, и оно переживает
# любые пересборки.
set -euo pipefail

APP="build/Build/Products/Release/AppMixer.app"
SIGN_DIR="$HOME/Library/Application Support/AppMixer/signing"
CERT="$SIGN_DIR/cert.pem"
KEY="$SIGN_DIR/key.pem"
cd "$(dirname "$0")/.."

# 0. rcodesign — готовый бинарник с GitHub-релизов (в Homebrew его нет,
#    а brew install cosign — это другой инструмент).
RCODESIGN="$HOME/Library/Application Support/AppMixer/bin/rcodesign"
if [[ ! -x "$RCODESIGN" ]]; then
    echo "→ Скачиваю rcodesign (один раз)…"
    BIN_DIR="$(dirname "$RCODESIGN")"
    mkdir -p "$BIN_DIR"
    ASSET_URL=$(curl -s https://api.github.com/repos/indygreg/apple-platform-rs/releases/latest \
        | grep -Eo '"browser_download_url": *"[^"]*"' \
        | grep -Ei 'apple_?codesign.*macos' \
        | grep -Eo 'https[^"]*' | head -1)
    [[ -n "$ASSET_URL" ]] || { echo "✗ Не нашёл релиз rcodesign на GitHub"; exit 1; }
    W="$(mktemp -d)"
    curl -sL -o "$W/dl" "$ASSET_URL"
    mkdir -p "$W/x"
    tar -xf "$W/dl" -C "$W/x" 2>/dev/null || unzip -q "$W/dl" -d "$W/x"
    FOUND="$(find "$W/x" -type f -name rcodesign | head -1)"
    [[ -n "$FOUND" ]] || { echo "✗ rcodesign не найден в архиве ($ASSET_URL)"; exit 1; }
    cp "$FOUND" "$RCODESIGN"
    chmod +x "$RCODESIGN"
    rm -rf "$W"
    echo "✓ rcodesign: $BIN_DIR"
fi

# 1. Сертификат и ключ — генерируются один раз, живут вне репозитория
#    (переживают удаление папки проекта).
mkdir -p "$SIGN_DIR"
chmod 700 "$SIGN_DIR"
if [[ ! -s "$CERT" || ! -s "$KEY" ]]; then
    echo "→ Генерирую самоподписанный сертификат…"
    if ! "$RCODESIGN" generate-self-signed-certificate \
        --certificate-out-path "$CERT" --private-key-out-path "$KEY" \
        --cn "AppMixer Dev" --valid-days 3650 2>/dev/null; then
        "$RCODESIGN" generate-self-signed-certificate \
            --certificate-out-path "$CERT" --private-key-out-path "$KEY"
    fi
    chmod 600 "$CERT" "$KEY"
    echo "✓ Сертификат и ключ: $SIGN_DIR"
fi

# 2. Сборка Release (без Apple-подписи — подпишем сами).
XCODEGEN="$( [[ -x .tools/xcodegen/bin/xcodegen ]] && echo .tools/xcodegen/bin/xcodegen || echo xcodegen )"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
"$XCODEGEN" generate
xcodebuild -project AppMixer.xcodeproj -scheme AppMixer -configuration Release \
    CODE_SIGNING_ALLOWED=NO -derivedDataPath build build \
    | grep -E "^\*\* BUILD" || true

# 3. Подпись файлами — без связок ключей, без диалогов.
"$RCODESIGN" sign --pem-source "$CERT" --key-source "$KEY" "$APP"

echo "✓ Подписано:"
codesign -dv "$APP" 2>&1 | grep -E "Identifier=|Signature=|Authority=" || true
if codesign --verify "$APP" 2>/dev/null; then
    echo "✓ Проверка подписи macOS пройдена."
fi

echo
echo "Установка (выполните):"
echo "  osascript -e 'quit app \"AppMixer\"' 2>/dev/null; rm -rf /Applications/AppMixer.app"
echo "  ditto $APP /Applications/AppMixer.app && open /Applications/AppMixer.app"
echo
echo "Первый запуск спросит разрешение на звук ОДИН последний раз:"
echo "сертификат стабильный, macOS запомнит навсегда."
echo
echo "Почистить следы экспериментов со Связкой ключей (по желанию):"
echo "  security delete-keychain ~/Library/Keychains/appmixer-signing.keychain-db"
echo "  rm -f ~/Desktop/AppMixer/.signing-secret"
