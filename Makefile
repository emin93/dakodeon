APP_NAME := Dakodeon
DIST_DIR := dist
APP := $(DIST_DIR)/$(APP_NAME).app
CONTENTS := $(APP)/Contents
RESOURCES := $(CONTENTS)/Resources
EXECUTABLE := .build/release/$(APP_NAME)
ICON := Assets/DakodeonIcon.png

.PHONY: build dist zip install run clean

build:
	swift build -c release

dist: build
	rm -rf "$(APP)"
	mkdir -p "$(CONTENTS)/MacOS" "$(RESOURCES)"
	cp "$(EXECUTABLE)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	cp Packaging/Info.plist "$(CONTENTS)/Info.plist"
	cp "$(ICON)" "$(RESOURCES)/DakodeonIcon.png"
	$(MAKE) "$(RESOURCES)/Dakodeon.icns"
	codesign --force --deep --sign - "$(APP)"

$(RESOURCES)/Dakodeon.icns: $(ICON)
	rm -rf "$(DIST_DIR)/Dakodeon.iconset"
	mkdir -p "$(DIST_DIR)/Dakodeon.iconset"
	sips -z 16 16     "$(ICON)" --out "$(DIST_DIR)/Dakodeon.iconset/icon_16x16.png" >/dev/null
	sips -z 32 32     "$(ICON)" --out "$(DIST_DIR)/Dakodeon.iconset/icon_16x16@2x.png" >/dev/null
	sips -z 32 32     "$(ICON)" --out "$(DIST_DIR)/Dakodeon.iconset/icon_32x32.png" >/dev/null
	sips -z 64 64     "$(ICON)" --out "$(DIST_DIR)/Dakodeon.iconset/icon_32x32@2x.png" >/dev/null
	sips -z 128 128   "$(ICON)" --out "$(DIST_DIR)/Dakodeon.iconset/icon_128x128.png" >/dev/null
	sips -z 256 256   "$(ICON)" --out "$(DIST_DIR)/Dakodeon.iconset/icon_128x128@2x.png" >/dev/null
	sips -z 256 256   "$(ICON)" --out "$(DIST_DIR)/Dakodeon.iconset/icon_256x256.png" >/dev/null
	sips -z 512 512   "$(ICON)" --out "$(DIST_DIR)/Dakodeon.iconset/icon_256x256@2x.png" >/dev/null
	sips -z 512 512   "$(ICON)" --out "$(DIST_DIR)/Dakodeon.iconset/icon_512x512.png" >/dev/null
	sips -z 1024 1024 "$(ICON)" --out "$(DIST_DIR)/Dakodeon.iconset/icon_512x512@2x.png" >/dev/null
	iconutil -c icns "$(DIST_DIR)/Dakodeon.iconset" -o "$@"

zip: dist
	rm -f "$(DIST_DIR)/Dakodeon.zip"
	cd "$(DIST_DIR)" && ditto -c -k --sequesterRsrc --keepParent "$(APP_NAME).app" Dakodeon.zip

install: dist
	cp -R "$(APP)" /Applications/

run: dist
	open "$(APP)"

clean:
	rm -rf .build "$(DIST_DIR)"
