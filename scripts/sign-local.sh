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
#    а brew install cosign — это другой инструмент). Версию определяем по
#    редиректу страницы releases/latest, без GitHub API (лимиты IP).
RCODESIGN="$HOME/Library/Application Support/AppMixer/bin/rcodesign"
if [[ ! -x "$RCODESIGN" ]]; then
    echo "→ Скачиваю rcodesign (один раз)…"
    BIN_DIR="$(dirname "$RCODESIGN")"
    mkdir -p "$BIN_DIR"
    VER="$(curl -sL -o /dev/null -w '%{url_effective}' \
        https://github.com/indygreg/apple-platform-rs/releases/latest \
        | grep -Eo 'apple-codesign/[0-9.]+' | cut -d/ -f2)"
    [[ -n "$VER" ]] || { echo "✗ Не определил последнюю версию rcodesign"; exit 1; }
    echo "  версия $VER"
    W="$(mktemp -d)"
    curl -sL --retry 3 -o "$W/rc.tar.gz" \
        "https://github.com/indygreg/apple-platform-rs/releases/latest/download/apple-codesign-$VER-macos-universal.tar.gz" \
        || { echo "✗ Скачивание не удалось"; rm -rf "$W"; exit 1; }
    tar -xzf "$W/rc.tar.gz" -C "$W" || { echo "✗ Архив повреждён"; rm -rf "$W"; exit 1; }
    FOUND="$(find "$W" -type f -name rcodesign | head -1)"
    [[ -n "$FOUND" ]] || { echo "✗ rcodesign не найден в архиве"; rm -rf "$W"; exit 1; }
    cp "$FOUND" "$RCODESIGN"
    chmod +x "$RCODESIGN"
    rm -rf "$W"
    echo "✓ rcodesign установлен: $BIN_DIR"
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
