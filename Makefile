APP_NAME := LanShare
APP_BUNDLE := dist/$(APP_NAME).app
CONTENTS := $(APP_BUNDLE)/Contents
MACOS := $(CONTENTS)/MacOS
RESOURCES := $(CONTENTS)/Resources
BIN := .build/release/$(APP_NAME)
SIGN_ID ?= -
INSTALL_DIR ?= /Applications

.PHONY: build run install clean

build:
	swift build -c release
	rm -rf $(APP_BUNDLE)
	mkdir -p $(MACOS) $(RESOURCES)
	cp $(BIN) $(MACOS)/$(APP_NAME)
	cp packaging/Info.plist $(CONTENTS)/Info.plist
	codesign --force --deep --sign "$(SIGN_ID)" $(APP_BUNDLE)
	@echo "构建完成: $(APP_BUNDLE)"

run: build
	open $(APP_BUNDLE)

install: build
	cp -R $(APP_BUNDLE) $(INSTALL_DIR)/$(APP_NAME).app
	codesign --force --deep --sign "$(SIGN_ID)" $(INSTALL_DIR)/$(APP_NAME).app
	@echo "安装完成: $(INSTALL_DIR)/$(APP_NAME).app"

clean:
	rm -rf .build dist
	@echo "已清理"
