#!/usr/bin/env bash
# M4-R5：厂商广告/遥测域名规则资产生成脚本。
#
# 来源：android-ad-cleaner 的包名单（AD_PKGS/QUICKAPP/MSA）反查对应 SDK 的
# 网络端点。候选域来自公开资料检索（SDK 官方文档/社区 hosts 去广告实践），
# **全部标注"待核对"**——按 AGENTS.md"宁可漏封不误封"，未经真机抓包核对前
# 本脚本只产出 build/rules-vendor-draft.txt（不进加载目录）；核对通过后再
# 人工并入 rules/（或订阅目录）。
#
# 用法：bash scripts/gen-vendor-rules.sh        # 产出 build/rules-vendor-draft.txt
# 核对方法（测试机，授权窗口）：AVD 装对应厂商 ROM 或真机 → 罗网内核 -v 日志
# 对照 traffic monitor；或直接抓包确认广告包（pm suspend 其余包后）的实际请求域。
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="build/rules-vendor-draft.txt"
mkdir -p build

emit() { printf '%s\n' "$*" >> "$OUT"; }

cat > "$OUT" <<'HDR'
! 厂商广告/遥测域名候选（M4-R5 草稿，全部待真机抓包核对）
! 来源：android-ad-cleaner 包名单反查 + 公开资料；未核对完成前不得并入生效目录。
! 核对清单：①该域确为广告/遥测端点（抓包确认请求方为广告 SDK 包）
!           ②同域不承载系统更新/商店/推送等正常功能（防误杀）
HDR

# ---- OPPO / 一加 / realme：com.opos.ads、com.heytap.pictorial ----
# 依据：OPPO 广告联盟（u.oppomobile.com）与营销平台文档；SDK 文档站挂在
# adsfs.heytapimage.com（Omni API）。待核对：哪些子域承载 SDK 实时请求。
for d in ads.oppomobile.com ocda.oppomobile.com adsfs.oppomobile.com adsfs.heytapimage.com; do
    emit "||${d}^	! 候选:OPPO opos.ads	待核对"
done

# ---- 小米 / Redmi：com.miui.systemAdSolution（米盟 MSA）----
# 依据：米盟 SDK 文档（dev.mi.com，日志关键字 zeus-mimo）与社区 hosts 去广告实践。
# 待核对：mistat 系列同时承载系统遥测，屏蔽影响面需实测评估。
for d in ad.xiaomi.com ad1.xiaomi.com tracking.miui.com data.mistat.com.cn; do
    emit "||${d}^	! 候选:小米 MSA/米盟	待核对"
done

# ---- 快应用引擎（OPPO/荣耀/华为/小米/vivo）----
cat >> "$OUT" <<'QA'
! 不做域名化候选：快应用资源走各厂商内容 CDN，与正常分发同域，域名级屏蔽
! 误杀风险不可接受。对应能力建议走 android-ad-cleaner 的包挂起路线。
! （快应用引擎 com.nearme.instant.* / com.hihonor.quickengine / com.miui.hybrid /
!   com.vivo.hybrid 等：不做域名拦截，走包挂起路线，见 android-ad-cleaner）
QA

echo "草稿已产出: $OUT（共 $(grep -c '||' "$OUT") 条候选，全部待核对）"
echo "核对通过后人工并入规则目录；未核对前不会进入任何加载路径。"
