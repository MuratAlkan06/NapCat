APP_NAME := NapCat
DIST     := dist
APP      := $(DIST)/$(APP_NAME).app
BINARY   := .build/release/$(APP_NAME)

# With Command Line Tools only (no Xcode.app), SwiftPM fails to pass -F for
# the toolchain's Testing.framework to its derived test-runner target, so a
# bare `swift test` builds but silently SKIPS test execution (exit 0 with no
# tests run — do not trust it as green). `make test` passes the flags at the
# CLI level, which reaches every target, so tests really execute.
# See PLAN.md decision log 2026-07-09.
CLT_FRAMEWORKS := /Library/Developer/CommandLineTools/Library/Developer/Frameworks

.PHONY: all run test clean frames smc

all:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BINARY) $(APP)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	install -m 0755 Resources/napcat-watchdog.sh $(APP)/Contents/Resources/napcat-watchdog.sh
	codesign --force -s - $(APP)

run: all
	pkill -x $(APP_NAME) || true
	open $(APP)

test:
	@if [ -d "$(CLT_FRAMEWORKS)" ]; then \
		swift test \
			-Xswiftc -F"$(CLT_FRAMEWORKS)" \
			-Xlinker -F"$(CLT_FRAMEWORKS)" \
			-Xlinker -rpath -Xlinker "$(CLT_FRAMEWORKS)"; \
	else \
		swift test; \
	fi

clean:
	rm -rf .build $(DIST)

frames:
	@echo "make frames: pixel-art frame rendering arrives in Phase 4"

smc:
	@echo "make smc: vendored smc build arrives in Phase 3"
