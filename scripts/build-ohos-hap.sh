#!/usr/bin/env bash
# 一键构建并安装罗网 HarmonyOS HAP（P0-H）：
#   1. libdragnet.so → ohos/entry/libs/x86_64/（须先跑 build-ohos.sh）
#   2. 种子规则 → rawfile（M4-R1：随分发包可见）
#   3. debug 签名块注入 ohos/build-profile.json5（从本机捐赠工程复制，不入库；
#      仓库内该文件 signingConfigs 保持空，注入后勿提交——脚本自动提醒）
#   4. devecocli build + hdc install
# 用法：bash scripts/build-ohos-hap.sh [捐赠工程目录] [hdc目标]
#   捐赠工程缺省 D:\HarmonyOS_Develop\Cimoc（其 debug profile 设备白名单含本机
#   模拟器；bundleName 绑定 com.march.cimoc，见 ohos/README.md）
# Git Bash 下运行。

set -euo pipefail

DONOR="${1:-/d/HarmonyOS_Develop/Cimoc}"
TARGET="${2:-127.0.0.1:5555}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROF="$ROOT/ohos/build-profile.json5"

# 1. 内核 .so
if [ ! -f "$ROOT/build/ohos/x86_64/libdragnet.so" ]; then
  echo "错误: 先跑 bash scripts/build-ohos.sh 产出内核" >&2
  exit 1
fi
mkdir -p "$ROOT/ohos/entry/libs/x86_64" "$ROOT/ohos/entry/src/main/resources/rawfile/rules"
cp "$ROOT/build/ohos/x86_64/libdragnet.so" "$ROOT/ohos/entry/libs/x86_64/"

# 2. 种子规则
cp "$ROOT/rules/starter.txt" "$ROOT/rules/protected-allow.txt" \
   "$ROOT/ohos/entry/src/main/resources/rawfile/rules/"

# 3. 签名注入（幂等：已注入则跳过）
if ! grep -q "storeFile" "$PROF"; then
  if [ ! -f "$DONOR/build-profile.json5" ]; then
    echo "错误: 捐赠工程不存在: $DONOR（或手动在 ohos/build-profile.json5 配签名）" >&2
    exit 1
  fi
  python - "$DONOR" "$PROF" <<'EOF'
import re, sys
donor = open(sys.argv[1] + r'\build-profile.json5', encoding='utf-8').read()
m = re.search(r'"signingConfigs"\s*:\s*\[.*?\]\s*,', donor, re.S)
if not m:
    sys.exit('donor has no signingConfigs')
target = open(sys.argv[2], encoding='utf-8').read()
open(sys.argv[2], 'w', encoding='utf-8').write(
    target.replace('"signingConfigs": [],', m.group(0)))
EOF
  echo "已注入 debug 签名（本机材料；提交前须还原 ohos/build-profile.json5）"
fi

# 4. 构建 + 安装
cd "$ROOT/ohos"
devecocli build

export MSYS_NO_PATHCONV=1
hdc -t "$TARGET" shell bm uninstall -n com.march.cimoc >/dev/null 2>&1 || true
hdc -t "$TARGET" install "entry/build/default/outputs/default/entry-default-signed.hap"
hdc -t "$TARGET" shell aa start -a EntryAbility -b com.march.cimoc
echo "完成。验证步骤见 ohos/README.md。"
