ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NoteDetailMonitor

NoteDetailMonitor_FILES = Tweak.xm
NoteDetailMonitor_FRAMEWORKS = UIKit Foundation
NoteDetailMonitor_CFLAGS = -fobjc-arc -Wall -Wextra

include $(THEOS_MAKE_PATH)/tweak.mk
