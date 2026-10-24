#!/usr/bin/env bash
# 拉取 demo/基准用规则订阅到 build/rules/（该目录被 .gitignore 忽略，不入库）。
# 规则地址均来自调研报告 docs/research/03 的官方渠道，勿换第三方镜像。
#
# 用法：
#   bash scripts/fetch-rules.sh                       # 直连（anti-AD 可达即可）
#   PROXY=http://127.0.0.1:7890 bash scripts/fetch-rules.sh   # GitHub 源需代理时
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/rules

fetch() {
    local url=$1 out=$2
    local args=(-fsSL --retry 3 --connect-timeout 15 -o "$out")
    if [ -n "${PROXY:-}" ]; then
        args+=(-x "$PROXY")
    fi
    echo ">> $out  <-  $url"
    curl "${args[@]}" "$url"
}

fetch "https://anti-ad.net/adguard.txt" \
    "build/rules/anti-AD.txt"
fetch "https://raw.githubusercontent.com/TG-Twilight/AWAvenue-Ads-Rule/main/Filters/AWAvenue-Ads-Rule-Adguard.txt" \
    "build/rules/AWAvenue.txt"
fetch "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/multi.txt" \
    "build/rules/hagezi-multi.txt"

echo "---- 完成 ----"
wc -c build/rules/*.txt
