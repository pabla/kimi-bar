PROJECT := KimiBar.xcodeproj
SCHEME := KimiBar
CONFIGURATION := Debug
XCODEBUILD = xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination 'platform=macOS'
APP = $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -showBuildSettings 2>/dev/null | awk -F ' = ' '/ BUILT_PRODUCTS_DIR = / { dir = $$2 } / FULL_PRODUCT_NAME = / { name = $$2 } END { print dir "/" name }')
RELEASE_DIR := .build/release
RELEASE_APP := .build/DerivedData/Build/Products/Release/KimiBar.app

.PHONY: build test restart release

release: CONFIGURATION = Release

build:
	$(XCODEBUILD) build

test:
	$(XCODEBUILD) test

release:
	$(XCODEBUILD) -derivedDataPath .build/DerivedData ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
	mkdir -p "$(RELEASE_DIR)"
	set -e; \
	version=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(RELEASE_APP)/Contents/Info.plist"); \
	archive="$(RELEASE_DIR)/KimiBar-v$$version.zip"; \
	rm -f "$$archive"; \
	ditto -c -k --keepParent "$(RELEASE_APP)" "$$archive"; \
	printf 'Created %s\n' "$$archive"

restart: build
	-pkill -x KimiBar
	sleep 1
	open "$(APP)"
