.PHONY: build app sign install run clean uninstall

PRODUCT    = DockLock
BUILD_DIR  = .build/release
APP_BUNDLE = $(BUILD_DIR)/$(PRODUCT).app
INSTALL_DIR = /Applications

build:
	swift build -c release

app: build
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp $(BUILD_DIR)/$(PRODUCT) $(APP_BUNDLE)/Contents/MacOS/
	@cp Resources/Info.plist $(APP_BUNDLE)/Contents/
	@echo "Built $(APP_BUNDLE)"

sign: app
	@codesign --force --sign - $(APP_BUNDLE)
	@echo "Signed $(APP_BUNDLE)"

install: sign
	@rm -rf $(INSTALL_DIR)/$(PRODUCT).app
	@cp -R $(APP_BUNDLE) $(INSTALL_DIR)/
	@echo "Installed to $(INSTALL_DIR)/$(PRODUCT).app"

run: sign
	@open $(APP_BUNDLE)

clean:
	swift package clean
	@rm -rf $(APP_BUNDLE)

uninstall:
	@rm -rf $(INSTALL_DIR)/$(PRODUCT).app
	@echo "Removed $(INSTALL_DIR)/$(PRODUCT).app"
