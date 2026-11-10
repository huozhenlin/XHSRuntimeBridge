ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FLEXInjector

# The official FLEX sources are copied into Vendor/FLEX by the GitHub
# workflow. Keeping the source acquisition in the workflow makes the build
# reproducible without vendoring a third-party binary.
FLEX_SOURCES := $(shell find Vendor/FLEX/Classes -type f \( -name '*.m' -o -name '*.mm' -o -name '*.c' \))
FLEX_INCLUDE_DIRS := $(shell find Vendor/FLEX/Classes -type d -print | sed 's/^/-I/')

FLEXInjector_FILES = Tweak.xm $(FLEX_SOURCES)
FLEXInjector_FRAMEWORKS = Foundation UIKit CoreGraphics ImageIO QuartzCore WebKit Security SceneKit
FLEXInjector_LIBRARIES = z sqlite3 c++
FLEXInjector_CFLAGS = -fobjc-arc -Wno-unsupported-availability-guard -Wno-deprecated-declarations $(FLEX_INCLUDE_DIRS)
FLEXInjector_CCFLAGS = -std=c++11 -stdlib=libc++
FLEXInjector_INSTALL = 0

include $(THEOS_MAKE_PATH)/tweak.mk
