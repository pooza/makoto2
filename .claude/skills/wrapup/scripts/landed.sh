#!/usr/bin/env bash
# 着地した Issue を並べる（wrapup 1.）。⚠ 読むだけ。
#
#   .claude/skills/wrapup/scripts/landed.sh [YYYY-MM-DD]   # 既定は今日（JST）
#
# その日以降に develop へマージされた PR と、本文・題に出てくる Issue 番号（#n）を出す。
# ⚠ develop 宛の PR では Closes #n が効かないので、Issue は open のまま残っている（閉じるかは手で決める）。
set -u
since=${1:-$(TZ=Asia/Tokyo date +%F)}
repo=pooza/makoto2
prs=$(gh pr list --repo "$repo" --state merged --base develop --search "merged:>=$since" --limit 50 \
  --json number,title,body,mergedAt) || { echo "⚠ PR の一覧が引けない"; exit 1; }
echo "== $since 以降に develop へ入った PR"
printf '%s' "$prs" | jq -r '.[] | "  #\(.number) \(.title)"'
echo "== 出てくる Issue（PR の番号は除く）"
nums=$(printf '%s' "$prs" | jq -r '[.[] | (.title + " " + .body) | scan("(?<![\\w/])#([0-9]+)") | .[0]] | unique | .[]')
prnums=$(printf '%s' "$prs" | jq -r '.[].number')
for n in $nums; do
  printf '%s\n' "$prnums" | grep -qx "$n" && continue
  gh issue view "$n" --repo "$repo" --json number,title,state,milestone \
    --jq '"  #\(.number) [\(.state)] (\(.milestone.title // "マイルストーンなし")) \(.title)"' 2>/dev/null
done
