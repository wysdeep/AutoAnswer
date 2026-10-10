#!/bin/bash
# 一键编译（在装有 Theos + ellekit 的 macOS 上运行）
# 用法： cd trollstore_tweak && bash build.sh
set -e
export THEOS="${THEOS:-$HOME/theos}"
if [ ! -d "$THEOS" ]; then
  echo "未找到 Theos，请先安装：https://theos.dev  (或 \$THEOS/bin/install_theos)"
  exit 1
fi
make clean
make
echo ""
echo "✅ 产物：.theos/obj/AutoAnswer.dylib"
echo "   连同 questions.json 用 TrollFools 注入「手机淘宝」IPA，再经 TrollStore 安装。"
