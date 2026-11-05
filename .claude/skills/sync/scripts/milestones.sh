#!/usr/bin/env bash
# マイルストーンの件数と重みを実測する（同期 10.）。⚠ 読むだけ。
#
#   .claude/skills/sync/scripts/milestones.sh
#
# 🔴 --state all で数える（表の重みは「その箱に入れた全部」で、閉じた Issue も残る）。
# 🔴 手で足し引きしない。重みを書き換える回は、この出力を見てから書く。
# 重み: size:L = 8 / size:M = 3 / size:S = 1 / 無し = 0。
set -u
repo=pooza/makoto2
doc=${1:-docs/CLAUDE.md}
gh api --paginate "repos/$repo/milestones?state=all&per_page=100" --jq '.[] | "\(.title)\t\(.state)"' |
  while IFS=$'\t' read -r title state; do
    json=$(gh issue list --repo "$repo" --state all --milestone "$title" --limit 200 --json number,labels) || { echo "⚠ $title: 取得に失敗した"; continue; }
    measured=$(echo "$json" | jq -r '[.[] | (.labels | map(.name))
      | (if index("size:L") then 8 elif index("size:M") then 3 elif index("size:S") then 1 else 0 end)]
      | "件数=\(length) 重み=\(add // 0)"')
    # ⚠ docs の表の行はセルの数で見る（重みの欄に説明文が出たら列が崩れている）。
    row=$(awk -v tag="$title" 'index($0, "| `" tag "`") == 1 || index($0, "| ~~`" tag "`~~") == 1 {
      n = gsub(/\|/, "|"); c = split($0, a, "|"); gsub(/^ +| +$/, "", a[c - 1])
      printf "表=%s%s", a[c - 1], (n == 4 ? "" : " ⚠ 列がずれている"); exit }' "$doc")
    printf '%-10s %-6s %s %s\n' "$title" "$state" "$measured" "${row:-表=（行なし）}"
  done | sort -V
