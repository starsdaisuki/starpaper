APP      := StarPaper
BUNDLE   := build/$(APP).app
BIN      := .build/release/$(APP)
INSTALL_DIR := $(HOME)/Applications

.PHONY: all build bundle run install clean kill dmg link icon test

all: bundle

build:
	swift build -c release --disable-sandbox

bundle: build
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	@printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	@codesign --force --sign - --timestamp=none $(BUNDLE) >/dev/null 2>&1 || true
	@echo "→ $(BUNDLE)"

# 杀掉正在跑的实例（改完代码重跑必用）
kill:
	@pkill -x $(APP) 2>/dev/null || true
	@sleep 0.3

run: kill bundle
	@open $(BUNDLE)
	@echo "→ StarPaper 已启动，看菜单栏 ✧"

install: bundle
	@mkdir -p $(INSTALL_DIR)
	@rm -rf $(INSTALL_DIR)/$(APP).app
	@cp -R $(BUNDLE) $(INSTALL_DIR)/
	@echo "→ 已装到 $(INSTALL_DIR)/$(APP).app"

# 打成 dmg。个人用完全不需要 —— 双击 .app 就能跑，dmg 只是给别人下载时的包装。
dmg: bundle
	@rm -f build/$(APP).dmg
	@rm -rf build/dmgroot && mkdir -p build/dmgroot
	@cp -R $(BUNDLE) build/dmgroot/
	@ln -s /Applications build/dmgroot/Applications
	@hdiutil create -volname $(APP) -srcfolder build/dmgroot -ov -format UDZO build/$(APP).dmg >/dev/null
	@rm -rf build/dmgroot
	@echo "→ build/$(APP).dmg"
	@echo "  注意：ad-hoc 签名的 app 别人下载后会报「已损坏」，需要 xattr -dr com.apple.quarantine"
	@echo "  要彻底免这一步得有 Apple Developer 账号（\$$99/年）做公证。"

# 设置层自检（不碰界面就能验「改了会不会被自己冲掉」）
test: bundle
	@STARPAPER_SELFTEST=1 ./$(BUNDLE)/Contents/MacOS/$(APP)

# 重新生成图标（改了 tools/make-icon.swift 之后跑）
icon:
	@swift tools/make-icon.swift
	@iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "→ Resources/AppIcon.icns"

# 把 CLI 挂到 PATH 上
link:
	@mkdir -p $(HOME)/.local/bin
	@ln -sf $(CURDIR)/bin/starpaper $(HOME)/.local/bin/starpaper
	@echo "→ $(HOME)/.local/bin/starpaper"
	@echo "  确认 ~/.local/bin 在 PATH 里，然后 starpaper --help"

clean:
	rm -rf .build build
