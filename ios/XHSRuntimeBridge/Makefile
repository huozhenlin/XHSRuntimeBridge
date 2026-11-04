ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = XHSRuntimeBridge

XHSRuntimeBridge_FILES = \
	Sources/XHSRuntimeBridge.m \
	Sources/XHSRuntimeLogger.m
XHSRuntimeBridge_CFLAGS = -fobjc-arc -Wall -Wextra
XHSRuntimeBridge_FRAMEWORKS = Foundation
XHSRuntimeBridge_INSTALL_PATH = /usr/local/lib

include $(THEOS_MAKE_PATH)/library.mk
