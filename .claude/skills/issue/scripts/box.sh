#!/usr/bin/env bash
# 箱（マイルストーン）の説明文に 1 行足し、末尾の「重み N（件数 M・日付 実測）」を実測で書き直す（issue 3.）。
#
#   .claude/skills/issue/scripts/box.sh <箱> '<足す行>'           # 差分を見せるだけ（書かない）
#   .claude/skills/issue/scripts/box.sh <箱> '<足す行>' --apply   # GitHub へ書く
#
# 足す行の {before} は説明文に書いてあった最後の重み、{after} は実測の重みに置き換わる。
#   例: '⚠ **2026-11-05 に #600 を追加**（`size:S`・**重み {before} → {after}**）— 要旨（オーナー判断）'
# 🔴 重みは手で足し引きしない（実測を書く）。⚠ 移したときは、出した箱と入れた箱の両方で回す。
# ⚠ 足す行を空（''）にすると、末尾の重みだけを実測に直す。
set -u
repo=pooza/makoto2
title=${1:?箱の名前を指定する（例 0.9）}
line=${2?足す行を指定する（空でもよい）}
apply=${3:-}
number=$(gh api --paginate "repos/$repo/milestones?state=all&per_page=100" \
  --jq ".[] | select(.title == \"$title\") | .number")
if [ -z "$number" ]; then
  echo "🔴 箱「$title」が無い"
  exit 1
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh api "repos/$repo/milestones/$number" --jq '.description // ""' > "$work/old"
measured=$(gh issue list --repo "$repo" --state all --milestone "$title" --limit 200 --json labels --jq '[.[] | (.labels | map(.name))
  | (if index("size:L") then 8 elif index("size:M") then 3 elif index("size:S") then 1 else 0 end)]
  | "\(add // 0) \(length)"')
# shellcheck disable=SC2016 # ruby のコードなので展開しない
LINE="$line" WEIGHT="${measured% *}" COUNT="${measured#* }" TODAY=$(TZ=Asia/Tokyo date +%F) \
  ruby -e '
    text = File.read(ARGV[0]).rstrip
    before = text.scan(/重み\s*(\d+)(?:\s*→\s*(\d+))?/).last
    before = before ? (before[1] || before[0]) : "?"
    # 末尾の合計の行（「重み N（件数 M・…実測）」だけの行）は外して、最後に書き直す。
    lines = text.lines.map(&:rstrip)
    lines.pop while lines.any? && (lines.last.empty? || lines.last.match?(/\A重み \d+（件数 \d+・[^）]*実測）\z/))
    add = ENV["LINE"].gsub("{before}", before).gsub("{after}", ENV["WEIGHT"])
    lines += ["", add] unless add.empty?
    lines += ["", "重み #{ENV["WEIGHT"]}（件数 #{ENV["COUNT"]}・#{ENV["TODAY"]} 実測）"]
    File.write(ARGV[1], lines.join("\n") + "\n")
  ' "$work/old" "$work/new"
diff -u --label "$title（いま）" --label "$title（書いたあと）" "$work/old" "$work/new"
if [ "$apply" = --apply ]; then
  gh api -X PATCH "repos/$repo/milestones/$number" -F "description=@$work/new" --jq '"✅ \(.title) の説明文を書いた"'
else
  echo "⚠ まだ書いていない（よければ --apply を付けてもう一度）"
fi
