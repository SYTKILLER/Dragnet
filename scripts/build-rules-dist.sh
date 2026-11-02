#!/usr/bin/env bash
# 构建对外发布的规则订阅产物（方向2）：拉三源 + 本项目种子规则，
# 经 cmd/ruleexport 归一/去重/保护排除/冗余收缩后输出到 build/rules-dist/。
# 规则地址与 fetch-rules.sh 一致（docs/research/03 官方渠道）。
#
# 用法：
#   bash scripts/build-rules-dist.sh                              # 直连（anti-AD 可达即可）
#   PROXY=http://127.0.0.1:7890 bash scripts/build-rules-dist.sh  # GitHub 源需代理时
#
# 可选 env：BASE_URL 覆盖写进产物 README 的订阅基地址（默认 rules-dist 分支 raw 地址）。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=build/rules-dist-src
OUT=build/rules-dist
LABEL=$(date +%F)
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/SYTKILLER/Dragnet/rules-dist}"

fetch() {
    local url=$1 out=$2
    local args=(-fsSL --retry 3 --connect-timeout 15 -o "$out")
    if [ -n "${PROXY:-}" ]; then
        args+=(-x "$PROXY")
    fi
    echo ">> $out  <-  $url"
    curl "${args[@]}" "$url"
}

mkdir -p "$SRC"
# 破坏性命令说明：清空 build/rules-dist —— 对象是上一次构建的发布产物目录，
# 重建前移除以免旧文件残留混入本次发布（源码工作区不受影响）。
rm -rf "$OUT"

# anti-AD：主源不可达时回退官方镜像（打 WARN）
if ! fetch "https://anti-ad.net/adguard.txt" "$SRC/anti-AD.txt"; then
    echo "WARN: anti-ad.net 拉取失败，回退镜像 privacy-protection-tools/anti-AD" >&2
    fetch "https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/master/adguard.txt" \
        "$SRC/anti-AD.txt"
fi
fetch "https://raw.githubusercontent.com/TG-Twilight/AWAvenue-Ads-Rule/main/Filters/AWAvenue-Ads-Rule-Adguard.txt" \
    "$SRC/AWAvenue.txt"
fetch "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/multi.txt" \
    "$SRC/hagezi-multi.txt"

echo "---- ruleexport ----"
go run ./cmd/ruleexport \
    -in "$SRC/anti-AD.txt" \
    -in "$SRC/AWAvenue.txt" \
    -in "$SRC/hagezi-multi.txt" \
    -in rules/starter.txt \
    -allow rules/protected-allow.txt \
    -out "$OUT" \
    -base-url "$BASE_URL" \
    -label "$LABEL"

# 完整性自检（失败不假报成功）：阻断域名总数 < 10000 视为拉到空/坏源，报错退出。
total=$(wc -l < "$OUT/domains.txt" | tr -d '[:space:]')
if [ "$total" -lt 10000 ]; then
    echo "ERROR: 阻断域名总数 $total < 10000，疑似空/坏源，构建判定失败并中止" >&2
    exit 1
fi

echo "---- 完成：产物行数 ----"
wc -l "$OUT/adguard.txt" "$OUT/clash-classical.yaml" "$OUT/clash-domain.yaml" \
      "$OUT/domains.txt" "$OUT/hosts" \
      "$OUT/allow/adguard.txt" "$OUT/allow/clash-classical.yaml"
echo "---- manifest 摘要 ----"
cat "$OUT/manifest.json"
