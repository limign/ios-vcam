ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

# 目标环境为 Dopamine-roothide / roothide Bootstrap：
# 必须使用 roothide 打包方案，产出 Architecture: iphoneos-arm64e 的 deb，
# 包内路径按 rootful 布局（/Library/...），安装时由 roothide 的 dpkg 自动映射进 jbroot。
# 需要 roothide 版 theos: https://github.com/roothide/theos
# 如需编译传统 rootless 包: make package THEOS_PACKAGE_SCHEME=rootless
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCam

VCam_FILES = Tweak.xm MediaManager.m
VCam_CFLAGS = -fobjc-arc
VCam_CXXFLAGS = -fobjc-arc -std=c++17
VCam_LDFLAGS = -std=c++17
VCam_FRAMEWORKS = UIKit AVFoundation CoreMedia CoreVideo CoreImage MobileCoreServices
VCam_PRIVATE_FRAMEWORKS =

include $(THEOS_MAKE_PATH)/tweak.mk

# SUBPROJECTS += vcamsettings  # Disabled: Preferences.framework not in iOS 16.5 SDK
# include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard"
