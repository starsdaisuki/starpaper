APP      := StarPaper
BUNDLE   := build/$(APP).app
BIN      := .build/release/$(APP)
APPSTORE_BUILD_DIR := .build-appstore
APPSTORE_BIN := $(APPSTORE_BUILD_DIR)/release/$(APP)
APPSTORE_BUNDLE := build/$(APP)-AppStore.app
APPSTORE_PKG := build/$(APP)-AppStore.pkg
# Mac App Store 描述文件。**不入库**（见 .gitignore）：它和账号绑定，别人 clone 下来也用不了。
# 生成：developer.apple.com → Certificates, Identifiers & Profiles → Profiles → +
#   → Mac App Store → 选本 app 的 bundle id 与 Apple Distribution 证书
#   → 下载后放到这个路径（也可以用 App Store Connect API 的 /v1/profiles 建）。
# ⚠️ 没有它照样能提交审核，只是 altool 会警告 90889：该 build 不能走 TestFlight。
APPSTORE_PROFILE ?= Resources/$(APP)-AppStore.provisionprofile
# 实际用于签名的 entitlements。**构建时生成**：以 Resources/*.entitlements 为底，
# 若存在描述文件，就把它里面的 com.apple.application-identifier 与
# com.apple.developer.team-identifier 读出来合进去。
# ⭐ 这么做是为了**不把 Team ID 写进源码仓**（公开仓不放账号标识符），
#    同时满足 TestFlight 的要求：签名里的 app 标识符必须和描述文件里的一致，
#    否则 altool 报 90886（能提交审核，但不能走 TestFlight）。
APPSTORE_ENT := build/appstore-entitlements.plist
INSTALL_DIR := $(HOME)/Applications
SIGNED_DMG := build/$(APP)-signed.dmg
# 公证凭据，二选一（notarytool 两种都吃）：
#   ① App Store Connect API key —— 设 ASC_KEY_ID 与 ASC_ISSUER 即可，私钥默认从
#      ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 取（也可用 ASC_KEY_P8 指定）。
#      这条不需要交互式终端，脚本和 CI 里能直接跑完。
#   ② 钥匙串凭据 profile —— 见 `make notarize-setup`，要在真终端里输一次 app 专用密码。
# 只要设了 ASC_KEY_ID 就优先走 ①，否则回落到 ②。
NOTARY_PROFILE ?= starpaper-notary
ASC_KEY_P8 ?= $(HOME)/.appstoreconnect/private_keys/AuthKey_$(ASC_KEY_ID).p8
NOTARY_AUTH = $(if $(ASC_KEY_ID),--key "$(ASC_KEY_P8)" --key-id "$(ASC_KEY_ID)" --issuer "$(ASC_ISSUER)",--keychain-profile $(NOTARY_PROFILE))

.PHONY: all build bundle run install clean kill dmg link icon test appstore-build appstore-check appstore-test \
        appstore-distribution-check appstore-package devid-check release-signed notarize-setup

all: bundle

build:
	swift build -c release --disable-sandbox

bundle: build
	@[ ! -e "$(BUNDLE)" ] || /usr/bin/trash "$(BUNDLE)"
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	@xcrun strip -S $(BUNDLE)/Contents/MacOS/$(APP)
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	@cp Resources/PrivacyInfo.xcprivacy $(BUNDLE)/Contents/Resources/PrivacyInfo.xcprivacy
	@cp Resources/blackhole-demo.mp4 $(BUNDLE)/Contents/Resources/blackhole-demo.mp4
	@printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	@codesign --force --sign - --timestamp=none $(BUNDLE)
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
	@[ ! -e "$(INSTALL_DIR)/$(APP).app" ] || /usr/bin/trash "$(INSTALL_DIR)/$(APP).app"
	@cp -R $(BUNDLE) $(INSTALL_DIR)/
	@echo "→ 已装到 $(INSTALL_DIR)/$(APP).app"

# 打成 dmg。个人用完全不需要 —— 双击 .app 就能跑，dmg 只是给别人下载时的包装。
dmg: bundle
	@[ ! -e "build/$(APP).dmg" ] || /usr/bin/trash "build/$(APP).dmg"
	@[ ! -e "build/dmgroot" ] || /usr/bin/trash "build/dmgroot"
	@mkdir -p build/dmgroot
	@cp -R $(BUNDLE) build/dmgroot/
	@ln -s /Applications build/dmgroot/Applications
	@hdiutil create -volname $(APP) -srcfolder build/dmgroot -ov -format UDZO build/$(APP).dmg >/dev/null
	@/usr/bin/trash build/dmgroot
	@echo "→ build/$(APP).dmg"
	@echo "  注意：ad-hoc 签名的 app 别人下载后会报「已损坏」，需要 xattr -dr com.apple.quarantine"
	@echo "  要免掉这一步：make release-signed（需要 Developer ID 证书）。"

# ── 发布签名与公证 ─────────────────────────────────────────────────────────
# ad-hoc 签名的 .app 别人下载后一律被 Gatekeeper 拦（「已损坏」），这是公开仓
# 转化率的头号杀手。根治只有一条路：Developer ID Application 证书 + Hardened
# Runtime + 公证（notarization）+ stapling。前两样让 Gatekeeper 认得出是谁签的，
# 后两样让它在**离线**时也能验（stapler 把公证票据钉进 dmg 里）。

# 有没有 Developer ID 证书。没有就把该做什么直接打出来，别让人去猜报错。
devid-check:
	@security find-identity -v -p codesigning | grep -q "Developer ID Application" || { \
		echo "✗ 钥匙串里没有 Developer ID Application 证书。"; \
		echo ""; \
		echo "  Xcode → Settings → Apple Accounts → 选付费账号 → Manage Certificates"; \
		echo "  → 左下角 + → Developer ID Application，建完会自动装进登录钥匙串。"; \
		echo "  （这张证书和 Mac App Store 用的 Apple Distribution 是两张，别搞混）"; \
		exit 1; }
	@echo "→ 用证书：$$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | sed -E 's/^ *[0-9]+\) [0-9A-F]+ //')"

# 一次性：把 App Store Connect 凭据存进钥匙串，之后 notarytool 不用再输密码。
# ⚠️ 这条要你自己在终端跑（要输密码），Makefile 只负责把命令拼对。
notarize-setup:
	@echo "路线 ①（推荐，不用交互式终端）：用 App Store Connect API key —— "
	@echo "  把 .p8 放到 ~/.appstoreconnect/private_keys/，然后："
	@echo ""
	@echo "  make release-signed ASC_KEY_ID=<KeyID> ASC_ISSUER=<IssuerUUID>"
	@echo ""
	@echo "  key 在 App Store Connect → 用户与访问 → 集成 → 单个密钥 里建，"
	@echo "  角色给 Developer 或 App Manager 即可；.p8 只能下载一次。"
	@echo ""
	@echo "路线 ②：钥匙串凭据 profile。⚠️ 这条要你自己在终端里跑（要输密码）："
	@echo ""
	@echo "  xcrun notarytool store-credentials $(NOTARY_PROFILE) \\"
	@echo "    --apple-id <你的 Apple ID> --team-id <TeamID> --password <app 专用密码>"
	@echo ""
	@echo "  app 专用密码在 https://account.apple.com → 登录与安全 → App 专用密码 生成，"
	@echo "  不是 Apple ID 本身的密码。TeamID 见 https://developer.apple.com/account 右上角。"

release-signed: devid-check bundle
	@id=$$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/'); \
	echo "→ 签名（Hardened Runtime + 安全时间戳）"; \
	codesign --force --deep --options runtime --timestamp --sign "$$id" $(BUNDLE)
	@codesign --verify --deep --strict --verbose=2 $(BUNDLE)
	@echo "→ 打 dmg"
	@[ ! -e "$(SIGNED_DMG)" ] || /usr/bin/trash "$(SIGNED_DMG)"
	@[ ! -e "build/dmgroot" ] || /usr/bin/trash "build/dmgroot"
	@mkdir -p build/dmgroot
	@cp -R $(BUNDLE) build/dmgroot/
	@ln -s /Applications build/dmgroot/Applications
	@hdiutil create -volname $(APP) -srcfolder build/dmgroot -ov -format UDZO $(SIGNED_DMG) >/dev/null
	@/usr/bin/trash build/dmgroot
	@id=$$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/'); \
	codesign --force --timestamp --sign "$$id" $(SIGNED_DMG)
	@echo "→ 提交公证（首次通常几分钟，--wait 会一直等）"
	@xcrun notarytool submit $(SIGNED_DMG) $(NOTARY_AUTH) --wait
	@echo "→ 把公证票据钉进 dmg（钉了之后离线也能过 Gatekeeper）"
	@xcrun stapler staple $(SIGNED_DMG)
	@echo "→ 验收：以 Gatekeeper 的身份重新评估一次"
	@spctl --assess --type open --context context:primary-signature --verbose=2 $(SIGNED_DMG)
	@echo "✅ $(SIGNED_DMG)：签名 + 公证 + stapled，别人下载后双击即可打开"
	@echo "   （票据钉在 dmg 上；如果要单发 .app，得对 .app 或它的 zip 再 staple 一次）"

# 设置层自检（不碰界面就能验「改了会不会被自己冲掉」）
test: bundle
	@STARPAPER_SELFTEST=1 ./$(BUNDLE)/Contents/MacOS/$(APP)

# Mac App Store 只读体检包：用沙盒 entitlement 做本地 ad-hoc 签名，
# 并验证提交二进制里没有 SkyLight / CGS 私有 API 与本机绝对路径。
# 这不是可上传的 Distribution 包；正式提交仍要 Apple Distribution
# 与 Mac Installer Distribution 两张证书。当前 entitlements 不含需授权的 capability，
# 所以直接 App Store 上传不需 provisioning profile；TestFlight 另论。
appstore-build:
	swift build -c release --disable-sandbox --scratch-path $(APPSTORE_BUILD_DIR) \
		-Xswiftc -DSTARPAPER_APPSTORE

appstore-check: appstore-build
	@[ ! -e "$(APPSTORE_BUNDLE)" ] || /usr/bin/trash "$(APPSTORE_BUNDLE)"
	@mkdir -p $(APPSTORE_BUNDLE)/Contents/MacOS $(APPSTORE_BUNDLE)/Contents/Resources
	@cp $(APPSTORE_BIN) $(APPSTORE_BUNDLE)/Contents/MacOS/$(APP)
	@xcrun strip -S $(APPSTORE_BUNDLE)/Contents/MacOS/$(APP)
	@cp Resources/Info.plist $(APPSTORE_BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(APPSTORE_BUNDLE)/Contents/Resources/AppIcon.icns
	@cp Resources/PrivacyInfo.xcprivacy $(APPSTORE_BUNDLE)/Contents/Resources/PrivacyInfo.xcprivacy
	@cp Resources/blackhole-demo.mp4 $(APPSTORE_BUNDLE)/Contents/Resources/blackhole-demo.mp4
	@printf 'APPL????' > $(APPSTORE_BUNDLE)/Contents/PkgInfo
	@cp Resources/$(APP)-AppStore.entitlements $(APPSTORE_ENT)
	@if [ -f "$(APPSTORE_PROFILE)" ]; then \
		cp "$(APPSTORE_PROFILE)" $(APPSTORE_BUNDLE)/Contents/embedded.provisionprofile; \
		security cms -D -i "$(APPSTORE_PROFILE)" \
			| plutil -extract Entitlements xml1 -o build/profile-entitlements.plist -; \
		appid=$$(/usr/libexec/PlistBuddy -c "Print :com.apple.application-identifier" build/profile-entitlements.plist); \
		team=$$(/usr/libexec/PlistBuddy -c "Print :com.apple.developer.team-identifier" build/profile-entitlements.plist); \
		/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $$appid" $(APPSTORE_ENT); \
		/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $$team" $(APPSTORE_ENT); \
		echo "→ 已嵌入描述文件，并把 $$appid 合进 entitlements（TestFlight 需要）"; \
	else \
		echo "⚠️  找不到 $(APPSTORE_PROFILE)：包仍可提交审核，但 altool 会警告 90889，该 build 不能走 TestFlight"; \
	fi
	@codesign --force --sign - --timestamp=none --options runtime \
		--entitlements $(APPSTORE_ENT) $(APPSTORE_BUNDLE)
	@! LC_ALL=C rg -a -q 'SkyLight[.]framework|CGS(MainConnectionID|CopyManagedDisplaySpaces|MoveWindowsToManagedSpace|CopySpacesForWindows)' $(APPSTORE_BUNDLE)/Contents/MacOS/$(APP)
	@! LC_ALL=C rg -a -q '/Users/' $(APPSTORE_BUNDLE)/Contents/MacOS/$(APP)
	@codesign --verify --deep --strict --verbose=2 $(APPSTORE_BUNDLE)
	@echo "→ $(APPSTORE_BUNDLE) (本地沙盒体检包，非上传包)"

appstore-test: appstore-check
	@STARPAPER_SELFTEST=1 ./$(APPSTORE_BUNDLE)/Contents/MacOS/$(APP)

# 可上传 pkg 的证书门禁。不用模糊的 codesign 报错让人猜是缺哪张证书。
appstore-distribution-check:
	@app=$$(security find-identity -v -p codesigning | \
		sed -n 's/.*"\(Apple Distribution:[^"]*\)".*/\1/p' | head -1); \
	installer=$$(security find-identity -v -p basic | \
		sed -n 's/.*"\(3rd Party Mac Developer Installer:[^"]*\)".*/\1/p' | head -1); \
	missing=0; \
	if [ -z "$$app" ]; then \
		echo "✗ 缺 Apple Distribution 证书（给 .app 签名）"; missing=1; \
	else echo "→ app 证书：$$app"; fi; \
	if [ -z "$$installer" ]; then \
		echo "✗ 缺 3rd Party Mac Developer Installer 证书（给 .pkg 签名）"; missing=1; \
	else echo "→ installer 证书：$$installer"; fi; \
	if [ "$$missing" -ne 0 ]; then \
		echo ""; \
		echo "  先在 Apple Developer Certificates 页或 Xcode 账号证书管理里创建这两张，"; \
		echo "  装进登录钥匙串后重跑 make appstore-package。"; \
		exit 1; \
	fi

# 正式 Mac App Store 上传产物。MAS 包不走 Developer ID 公证链。
appstore-package: appstore-check appstore-distribution-check
	@app=$$(security find-identity -v -p codesigning | \
		sed -n 's/.*"\(Apple Distribution:[^"]*\)".*/\1/p' | head -1); \
	installer=$$(security find-identity -v -p basic | \
		sed -n 's/.*"\(3rd Party Mac Developer Installer:[^"]*\)".*/\1/p' | head -1); \
	echo "→ Apple Distribution 签名 .app"; \
	codesign --force --options runtime --timestamp --sign "$$app" \
		--entitlements $(APPSTORE_ENT) $(APPSTORE_BUNDLE); \
	codesign --verify --deep --strict --verbose=2 $(APPSTORE_BUNDLE); \
	[ ! -e "$(APPSTORE_PKG)" ] || /usr/bin/trash "$(APPSTORE_PKG)"; \
	echo "→ Mac Installer Distribution 签名 .pkg"; \
	productbuild --component $(APPSTORE_BUNDLE) /Applications \
		--sign "$$installer" "$(APPSTORE_PKG)"; \
	pkgutil --check-signature "$(APPSTORE_PKG)"; \
	echo "✅ $(APPSTORE_PKG) （可上传 App Store Connect）"

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
	@for path in .build .build-appstore build; do [ ! -e "$$path" ] || /usr/bin/trash "$$path"; done
