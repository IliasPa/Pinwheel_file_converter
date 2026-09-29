# Pinwheel — common commands. Run them from this folder in Terminal, e.g. `make run`.

BUILD_ROOT := $(HOME)/Library/Developer/Pinwheel
APP        := $(BUILD_ROOT)/Pinwheel.app
INSTALLED  := /Applications/Pinwheel.app

.PHONY: build run test install uninstall clean icon

build:            ## Build Pinwheel.app (outside OneDrive, in ~/Library/Developer/Pinwheel)
	@scripts/build-app.sh

run: build        ## Build, quit any running copy, and start the fresh build
	@pkill -x Pinwheel || true
	@sleep 0.5
	@open "$(APP)"

test:             ## Run the automated tests
	@scripts/test.sh

install: build    ## Build and copy into /Applications, then start it from there
	@pkill -x Pinwheel || true
	@sleep 0.5
	@rm -rf "$(INSTALLED)"
	@ditto "$(APP)" "$(INSTALLED)"
	@echo "==> Installed to $(INSTALLED)"
	@open "$(INSTALLED)"

uninstall:        ## Quit Pinwheel and remove it from /Applications
	@pkill -x Pinwheel || true
	@rm -rf "$(INSTALLED)"

clean:            ## Delete all build output
	@rm -rf "$(BUILD_ROOT)"

icon:             ## Redraw Support/AppIcon.icns from scripts/make-icon.swift
	@rm -rf "$(BUILD_ROOT)/AppIcon.iconset"
	@mkdir -p "$(BUILD_ROOT)"
	@swift scripts/make-icon.swift "$(BUILD_ROOT)/AppIcon.iconset"
	@iconutil -c icns "$(BUILD_ROOT)/AppIcon.iconset" -o Support/AppIcon.icns
	@echo "==> Wrote Support/AppIcon.icns"
