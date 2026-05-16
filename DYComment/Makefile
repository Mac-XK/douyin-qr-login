TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = Aweme

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DYComment

DYComment_FILES = Tweak.x BundleSpoof.x
DYComment_CFLAGS = -fobjc-arc
DYComment_FRAMEWORKS = UIKit Foundation
DYComment_PRIVATE_FRAMEWORKS =

include $(THEOS_MAKE_PATH)/tweak.mk
