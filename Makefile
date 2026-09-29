# Builds DTerm.app with the Xcode Command Line Tools only (no Xcode).
#
# Interface Builder files can't be compiled without Xcode (ibtool), so the
# bundle gets the pre-compiled nibs from CompiledNibs/ instead of the .xib files.
#
#   make                  build build/Release/DTerm.app for the host architecture
#   make build-universal  build build/Release/DTerm.app for arm64 + x86_64
#   make deploy           install DTerm.app in ~/Applications or /Applications
#   make dmg              build build/Release/DTerm.dmg
#   make clean            remove build/
#
# Overridable: ARCHS (default: host architecture), CODESIGN_IDENTITY ("-" = ad-hoc),
# CODESIGN_FLAGS, MACOSX_DEPLOYMENT_TARGET, SDKROOT, DEPLOY_HOME (for deploy).

APP_NAME        := DTerm
HOST_ARCH       := $(shell uname -m)
UNIVERSAL_ARCHS := arm64 x86_64

ARCHS                    ?= $(HOST_ARCH)
MACOSX_DEPLOYMENT_TARGET ?= 12.0
SDKROOT                  ?= $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
CODESIGN_IDENTITY        ?= -
CODESIGN_FLAGS           ?=
DEPLOY_HOME              ?= $(HOME)

empty :=
space := $(empty) $(empty)

BUILD_DIR   := build/Release
# One object directory per architecture set, so switching ARCHS never mixes objects
OBJ_DIR     := build/obj/$(subst $(space),-,$(strip $(ARCHS)))
BIN         := $(OBJ_DIR)/$(APP_NAME)
APP         := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS    := $(APP)/Contents
RES         := $(CONTENTS)/Resources
EXE         := $(CONTENTS)/MacOS/$(APP_NAME)
DMG         := $(BUILD_DIR)/$(APP_NAME).dmg
DMG_STAGING := $(BUILD_DIR)/dmg-staging

# Same versioning scheme as the Xcode project's "Revision" target
GIT_COUNT      := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
GIT_SHA        := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
GIT_DIRTY      := $(shell git diff --quiet 2>/dev/null || echo +)
VERSION        := 1.7.$(GIT_COUNT)
VERSION_PUBLIC := $(VERSION)-$(GIT_SHA)$(GIT_DIRTY)

CC           := clang
TARGET_FLAGS := $(foreach a,$(ARCHS),-arch $(a)) $(if $(SDKROOT),-isysroot "$(SDKROOT)") \
                -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET)
CFLAGS       := $(TARGET_FLAGS) -fobjc-arc -Os -include DTerm_Prefix.pch \
                -I. -IUtilities -I"Term Window" -IScriptingBridge -I"3rd party source/ShortcutRecorder" \
                -Wall -Wextra -Werror=implicit-function-declaration -Werror=incompatible-pointer-types \
                -DOBJC_OLD_DISPATCH_PROTOTYPES=0
LDFLAGS      := $(TARGET_FLAGS) -fobjc-arc -Wl,-dead_strip
FRAMEWORKS   := -framework Cocoa -framework Carbon -framework ScriptingBridge \
                -framework Security -framework IOKit -framework WebKit

srcs_in = $(filter %.m,$(shell ls "$(1)"))

ROOT_OBJS := $(patsubst %.m,$(OBJ_DIR)/root/%.o,$(call srcs_in,.))
UTIL_OBJS := $(patsubst %.m,$(OBJ_DIR)/util/%.o,$(call srcs_in,Utilities))
TERM_OBJS := $(patsubst %.m,$(OBJ_DIR)/term/%.o,$(call srcs_in,Term Window))
SR_OBJS   := $(patsubst %.m,$(OBJ_DIR)/sr/%.o,$(call srcs_in,3rd party source/ShortcutRecorder))
OBJS      := $(ROOT_OBJS) $(UTIL_OBJS) $(TERM_OBJS) $(SR_OBJS)

.PHONY: all build build-universal app deploy dmg clean

all: build

build: app

build-universal:
	@$(MAKE) build ARCHS="$(UNIVERSAL_ARCHS)"

define compile
@mkdir -p $(@D)
@echo "CC      $<"
@$(CC) $(CFLAGS) -MMD -MP -c "$<" -o $@
endef

# Static pattern rules: GNU Make 3.81 won't match plain pattern rules
# whose prerequisites contain (escaped) spaces.
$(ROOT_OBJS): $(OBJ_DIR)/root/%.o: %.m Makefile
	$(compile)
$(UTIL_OBJS): $(OBJ_DIR)/util/%.o: Utilities/%.m Makefile
	$(compile)
$(TERM_OBJS): $(OBJ_DIR)/term/%.o: Term\ Window/%.m Makefile
	$(compile)
$(SR_OBJS): $(OBJ_DIR)/sr/%.o: 3rd\ party\ source/ShortcutRecorder/%.m Makefile
	$(compile)

$(BIN): $(OBJS)
	@mkdir -p $(@D)
	@echo "LINK    $@ ($(ARCHS))"
	@$(CC) $(LDFLAGS) $(FRAMEWORKS) $(OBJS) -o $@

# The executable and resources are re-copied on every build, so the bundle
# always matches the current ARCHS and removed files don't linger.
app: $(BIN)
	@echo "BUNDLE  $(APP)"
	@rm -rf "$(RES)"
	@mkdir -p "$(RES)/Base.lproj" "$(RES)/en.lproj" "$(dir $(EXE))"
	@cp "$(BIN)" "$(EXE)"
	@cp CompiledNibs/RTFWindow.nib "$(RES)/"
	@cp CompiledNibs/Base.lproj/*.nib "$(RES)/Base.lproj/"
	@cp en.lproj/*.strings "$(RES)/en.lproj/"
	@ditto en.lproj/DTermHelp "$(RES)/en.lproj/DTermHelp"
	@cp Images/DTerm.icns Images/ProgressWhite-*.png "Images/Updates Prefs.png" "$(RES)/"
	@cp "3rd party source/ShortcutRecorder/Images/"* "$(RES)/"
	@cp Acknowledgments.rtf License.rtf "Growl Registration Ticket.growlRegDict" "$(RES)/"
	@cp Info.plist "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleExecutable -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleShortVersionString -string "$(VERSION_PUBLIC)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleVersion -string "$(VERSION)" "$(CONTENTS)/Info.plist"
	@plutil -replace LSMinimumSystemVersion -string "$(MACOSX_DEPLOYMENT_TARGET)" "$(CONTENTS)/Info.plist"
	@printf 'APPLDTrm' > "$(CONTENTS)/PkgInfo"
	@echo "SIGN    $(APP) (identity: $(CODESIGN_IDENTITY))"
	@codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_FLAGS) "$(APP)"
	@echo "Built   $(APP) $(VERSION_PUBLIC)"

deploy: app
	@if [ -d "$(DEPLOY_HOME)/Applications" ]; then \
		destination="$(DEPLOY_HOME)/Applications"; \
	else \
		destination="/Applications"; \
	fi; \
	staging="$$(mktemp -d "$$destination/.DTerm.deploy.XXXXXX")" || exit 1; \
	trap 'rm -rf "$$staging"' EXIT; \
	echo "DEPLOY  $(APP) -> $$destination/$(APP_NAME).app"; \
	ditto "$(APP)" "$$staging/$(APP_NAME).app" || exit 1; \
	rm -rf "$$destination/$(APP_NAME).app" || exit 1; \
	mv "$$staging/$(APP_NAME).app" "$$destination/$(APP_NAME).app" || exit 1

dmg: app
	@echo "DMG     $(DMG)"
	@rm -rf "$(DMG_STAGING)" "$(DMG)"
	@mkdir -p "$(DMG_STAGING)"
	@ditto "$(APP)" "$(DMG_STAGING)/$(APP_NAME).app"
	@ln -s /Applications "$(DMG_STAGING)/Applications"
	@hdiutil create -quiet -volname "$(APP_NAME)" -srcfolder "$(DMG_STAGING)" -ov -format UDZO "$(DMG)"
	@rm -rf "$(DMG_STAGING)"
	@echo "Built   $(DMG)"

clean:
	rm -rf build

-include $(OBJS:.o=.d)
