# Developer entry points.

XCODEPROJ := AppMixer.xcodeproj
SCHEME    := AppMixer

# TCC keys permission grants to the signing identity; unsigned (ad-hoc)
# debug builds get pinned to the binary hash and re-prompt on every
# rebuild. Sign with the local Developer ID when present; builds without
# the certificate fall back to no signing (build in Xcode with a personal
# team for a stable identity instead).
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -o '"Developer ID Application: [^"]*"' | head -1)
ifeq ($(SIGN_ID),)
SIGN_FLAGS := CODE_SIGNING_ALLOWED=NO
else
SIGN_FLAGS := CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=$(SIGN_ID)
endif

.PHONY: gen build test lint run install clean icon menubar-icon

gen:
	xcodegen generate

build: gen
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration Debug \
		$(SIGN_FLAGS) -derivedDataPath build build

test: gen
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration Debug \
		CODE_SIGNING_ALLOWED=NO -derivedDataPath build test

lint:
	pre-commit run --all-files

run: build
	open build/Build/Products/Debug/AppMixer.app

# Build + self-signed release into /Applications. Uses scripts/sign-local.sh
# (rcodesign, no Apple ID); the audio permission binds to the stable cert.
install:
	./scripts/sign-local.sh
	osascript -e 'quit app "AppMixer"' 2>/dev/null || true
	rm -rf /Applications/AppMixer.app
	ditto build/Build/Products/Release/AppMixer.app /Applications/AppMixer.app
	open /Applications/AppMixer.app

clean:
	rm -rf build $(XCODEPROJ)

# Regenerate the app icon from scripts/generate-icon.swift.
icon:
	swift scripts/generate-icon.swift /tmp/fader-icon-1024.png
	rm -rf /tmp/fader.iconset && mkdir -p /tmp/fader.iconset
	for size in 16 32 128 256 512; do \
		sips -z $$size $$size /tmp/fader-icon-1024.png --out /tmp/fader.iconset/icon_$${size}x$${size}.png > /dev/null; \
		sips -z $$((size * 2)) $$((size * 2)) /tmp/fader-icon-1024.png --out /tmp/fader.iconset/icon_$${size}x$${size}@2x.png > /dev/null; \
	done
	iconutil -c icns /tmp/fader.iconset -o Fader/Resources/Fader.icns

# Regenerate the menu bar template icon (1x + 2x).
menubar-icon:
	swift scripts/generate-menubar-icon.swift Fader/Resources
