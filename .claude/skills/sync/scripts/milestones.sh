#!/usr/bin/env bash
# マイルストーンの件数と重みを実測する（同期 10.）。⚠ 読むだけ。
#
#   .claude/skills/sync/scripts/milestones.sh
#
# 🔴 --state all で数える（表の重みは「その箱に入れた全部」で、閉じた Issue も残る）。
# 🔴 手で足し引きしない。重みを書き換える回は、この出力を見てから書く。
# 3 つ（実測・docs の表・GitHub の説明文）を 1 行に並べる。
# 重み: size:L = 8 / size:M = 3 / size:S = 1 / 無し = 0。
set -u
repo=pooza/makoto2
doc=${1:-docs/CLAUDE.md}
# 説明文の重みは、最後に出てくる「重み N」か「重み A → B」の B（足した行と末尾の合計のどちらでも拾う）。
gh api --paginate "repos/$repo/milestones?state=all&per_page=100" --jq '.[] | "\(.title)\t\(.state)\t\(
    [.description // "" | scan("重み\\s*([0-9]+)(?:\\s*→\\s*([0-9]+))?")] | last // [null] | .[1] // .[0] // "-")"' |
  while IFS=$'\t' read -r title state described; do
    json=$(gh issue list --repo "$repo" --state all --milestone "$title" --limit 200 --json number,labels) || { echo "⚠ $title: 取得に失敗した"; continue; }
    measured=$(echo "$json" | jq -r '[.[] | (.labels | map(.name))
      | (if index("size:L") then 8 elif index("size:M") then 3 elif index("size:S") then 1 else 0 end)]
      | "件数=\(length) 重み=\(add // 0)"')
    weight=${measured##*重み=}
    # ⚠ docs の表の行はセルの数で見る（重みの欄に説明文が出たら列が崩れている）。
    row=$(awk -v tag="$title" 'index($0, "| `" tag "`") == 1 || index($0, "| ~~`" tag "`~~") == 1 {
      n = gsub(/\|/, "|"); c = split($0, a, "|"); gsub(/^ +| +$/, "", a[c - 1])
      printf "表=%s%s", a[c - 1], (n == 4 ? "" : " ⚠ 列がずれている"); exit }' "$doc")
    # ⚠ 説明文に重みを書いていない箱は「-」（書いていないものは古くならない・ずれではない）。
    mark=""
    table=${row#表=}
    [ -n "$row" ] && [ "${table%% *}" != "$weight" ] && mark=" ⚠ 表が実測と違う"
    [ "$described" != - ] && [ "$described" != "$weight" ] && mark="$mark ⚠ 説明文が実測と違う"
    printf '%-10s %-6s %s %s 説明文=%s%s\n' "$title" "$state" "$measured" "${row:-表=（行なし）}" "$described" "$mark"
  done | sort -V
