# Theos 工程 Makefile（ellekit 注入，产出可被 TrollFools 注入的 dylib）
# 编译前需配置好 Theos 与 ellekit：
#   export THEOS=~/theos
#   ellekit 安装： $THEOS/bin/install_theos (或使用 procursus/ellekit 工具链)

TARGET := iphone:clang:16.5:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AutoAnswer
AutoAnswer_FILES = Tweak.x
AutoAnswer_CFLAGS = -fobjc-arc
AutoAnswer_FRAMEWORKS = UIKit Foundation
AutoAnswer_RESOURCES = questions.json

include $(THEOS_MAKE_PATH)/tweak.mk

# 编译后产物：.theos/obj/AutoAnswer.dylib  （连同 questions.json 资源）
# 用 TrollFools 把该 dylib 注入手机淘宝 IPA，再经 TrollStore 安装。

after-install::
	@echo "[*] dylib 已生成，请用 TrollFools 注入目标 App"

# 把最终 dylib 复制到 workflow 上传约定路径（.theos/obj/AutoAnswer.dylib）
# Theos/ellekit 实际产物在 .theos/obj/debug/arm64/，upload-artifact 路径需是确定的文件名
after-all::
	@for f in $$(find "$(THEOS_BUILD_DIR)/obj" -name '$(TWEAK_NAME).dylib' 2>/dev/null); do \
		cp "$$f" "$(THEOS_BUILD_DIR)/obj/$(TWEAK_NAME).dylib"; \
		echo "[*] 复制产物 -> $(THEOS_BUILD_DIR)/obj/$(TWEAK_NAME).dylib"; \
	done
