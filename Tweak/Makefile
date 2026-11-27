# Kubera Listener: Theos build (macOS + roothide/theos fork, see .github/workflows/tweak.yml)
#
# Loads into SpringBoard, an arm64e platform process: build on macOS with Xcode's clang, which tags the arm64e
# slice with the versioned ptrauth ABI (0x80000002). CI refuses to package anything else (verify_arm64e.py).
THEOS_PACKAGE_SCHEME ?= roothide
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = KuberaListener

KuberaListener_FILES = Tweak.m
KuberaListener_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable
KuberaListener_FRAMEWORKS = Foundation
# The two hooks are put in with the Objective-C runtime (KLHook in Tweak.m, as Shani does), so the dylib
# links iOS's own libraries only. ElleKit is still what loads it into SpringBoard.
KuberaListener_USE_SUBSTRATE = 0
KuberaListener_LDFLAGS = -Wl,-dead_strip_dylibs

include $(THEOS_MAKE_PATH)/tweak.mk
