# ModernOS — one tweak, one package, for iPhone 4S (armv7) on iOS 9.3.6.
TARGET := iphone:clang:9.3:9.0
ARCHS = armv7
INSTALL_TARGET_PROCESSES = SpringBoard
# iOS 9 ships dpkg 1.18; gzip is readable by every dpkg version.
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip
# `make package` never installs; `make install` is the explicit, manual step.

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ModernOS

ModernOS_FILES = Tweak.xm $(wildcard Sources/*.m) Sources/MODCrashGuardCore.c
ModernOS_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Werror
ModernOS_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics CoreText CFNetwork EventKit Accelerate

include $(THEOS_MAKE_PATH)/tweak.mk

# Host-side crash guard tests (no device needed).
test::
	@sh tests/run.sh
