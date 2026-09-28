# Builds DTerm.app with the Xcode Command Line Tools only (no Xcode).
#
# Interface Builder files can't be compiled without Xcode (ibtool), so the
# bundle gets the pre-compiled nibs from CompiledNibs/ instead of the .xib files.
#
#   make          build build/Release/DTerm.app
#   make dmg      build build/Release/DTerm.dmg
#   make clean    remove build/
#
# Overridable: ARCHS, CODESIGN_IDENTITY ("-" = ad-hoc), CODESIGN_FLAGS,
# MACOSX_DEPLOYMENT_TARGET, SDKROOT.

APP_NAME    := DTerm
BUILD_DIR   := build/Release
OBJ_DIR     := build/obj
APP         := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS    := $(APP)/Contents
RES         := $(CONTENTS)/Resources
EXE         := $(CONTENTS)/MacOS/$(APP_NAME)
DMG         := $(BUILD_DIR)/$(APP_NAME).dmg
DMG_STAGING := $(BUILD_DIR)/dmg-staging

ARCHS                    ?= arm64 x86_64
MACOSX_DEPLOYMENT_TARGET ?= 12.0
SDKROOT                  ?= $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
CODESIGN_IDENTITY        ?= -
CODESIGN_FLAGS           ?=

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

.PHONY: all build app dmg clean

all: build

build: app

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

$(EXE): $(OBJS)
	@mkdir -p $(@D)
	@echo "LINK    $@"
	@$(CC) $(LDFLAGS) $(FRAMEWORKS) $(OBJS) -o $@

# Resources are re-copied on every build so removed files don't linger.
app: $(EXE)
	@echo "BUNDLE  $(APP)"
	@rm -rf "$(RES)"
	@mkdir -p "$(RES)/Base.lproj" "$(RES)/en.lproj"
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
