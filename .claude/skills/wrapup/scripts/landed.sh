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
# 🔴 よそのリポジトリの番号を拾わない（#561）。`owner/repo#n` は # の直前が英数字なので外れる。
# ⚠ 「cure-api #396」「chubo2 #296」のように直前がリポジトリ名らしい小文字の語なら外す（Closes / Refs など
# の動詞と makoto2 は残す）。
nums=$(printf '%s' "$prs" | jq -r '[.[] | (.title + " " + .body)
  | scan("(?:([A-Za-z][A-Za-z0-9_.-]*)[ \\t])?(?<![\\w/])#([0-9]+)")
  | select(.[0] == null or (.[0] | test("^[a-z][a-z0-9]*(-[a-z0-9]+)*$") | not)
    or (.[0] | IN("close", "closes", "closed", "fix", "fixes", "fixed", "resolve", "resolves", "resolved",
      "ref", "refs", "see", "makoto2")))
  | .[1]] | unique | .[]')
prnums=$(printf '%s' "$prs" | jq -r '.[].number')
for n in $nums; do
  printf '%s\n' "$prnums" | grep -qx "$n" && continue
  gh issue view "$n" --repo "$repo" --json number,title,state,milestone \
    --jq '"  #\(.number) [\(.state)] (\(.milestone.title // "マイルストーンなし")) \(.title)"' 2>/dev/null
done
