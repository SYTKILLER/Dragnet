#!/usr/bin/env bash
# 幂等发布 build/rules-dist/ 为孤儿分支 rules-dist（每次生成无父提交的整树根提交）。
#
# 实现：临时 index + GIT_WORK_TREE 指向产物目录 + write-tree/commit-tree/update-ref
# 纯 plumbing，全程不触碰当前工作区与当前分支；push 用 --force
# （dist 分支语义就是整树覆盖，历次发布互不共祖，属预期行为）。
#
# 用法：
#   bash scripts/publish-rules-dist.sh              # 构建并推送
#   bash scripts/publish-rules-dist.sh --dry-run    # 演练到推送前一步，不改动任何 git 引用
set -euo pipefail
cd "$(dirname "$0")/.."

DIST=build/rules-dist
BRANCH=rules-dist

[ -d "$DIST" ] || { echo "ERROR: $DIST 不存在，先跑 scripts/build-rules-dist.sh" >&2; exit 1; }
[ -f "$DIST/manifest.json" ] || { echo "ERROR: $DIST/manifest.json 不存在，产物不完整" >&2; exit 1; }

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

generated_at=$(sed -n 's/.*"generated_at": *"\([^"]*\)".*/\1/p' "$DIST/manifest.json" | head -n 1)
[ -n "$generated_at" ] || generated_at=$(date -u +%FT%TZ)
commit_msg="rules-dist: $generated_at 自动构建（发布产物，勿手改）"

echo "---- 将发布到 $BRANCH 分支的内容 ----"
find "$DIST" -type f | sort
echo "---- 行数概览 ----"
wc -l "$DIST/adguard.txt" "$DIST/clash-classical.yaml" "$DIST/clash-domain.yaml" \
      "$DIST/domains.txt" "$DIST/hosts" \
      "$DIST/allow/adguard.txt" "$DIST/allow/clash-classical.yaml"
echo "---- 计划提交 ----"
echo "branch: $BRANCH（孤儿根提交，整树覆盖）"
echo "message: $commit_msg"

if [ "$DRY_RUN" = 1 ]; then
    echo "---- dry-run：演练到此为止（未建提交、未更新分支、未推送）----"
    exit 0
fi

TMP=$(mktemp -d)
# 破坏性命令说明：退出时清理 mktemp 临时目录（对象：本次发布的临时 index，进程退出后不再需要）。
trap 'rm -rf "$TMP"' EXIT

# 提交者身份仅用于 commit 元数据（CI runner 的 checkout 默认无 git 身份）
if [ -z "$(git config --get user.email || true)" ]; then
    git config user.name  "dragnet-bot"
    git config user.email "dragnet-bot@users.noreply.github.com"
fi

# 临时 index：GIT_WORK_TREE 指向 $DIST，使文件以分支根路径登记；
# -f 绕过 build/ 的 .gitignore（发布产物本就不该被忽略规则拦住）
export GIT_INDEX_FILE="$TMP/index"
export GIT_WORK_TREE="$PWD/$DIST"
git add -f -A .
tree=$(git write-tree)
# commit-tree 不带 -p → 孤儿根提交
commit=$(git commit-tree "$tree" -m "$commit_msg")
git update-ref "refs/heads/$BRANCH" "$commit"
unset GIT_INDEX_FILE GIT_WORK_TREE

echo ">> 已生成本地孤儿提交 $commit -> refs/heads/$BRANCH，内容如上"
git push --force origin "$BRANCH"
echo "---- 已推送 origin/$BRANCH ----"
