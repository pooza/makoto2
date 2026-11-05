#!/usr/bin/env bash
# 誕生日の原稿で、次の年のぶんを書くべき人を出す（同期 12.・#31）。⚠ 読むだけ。
#
#   .claude/skills/sync/scripts/birthday.sh [makoto-scripts の場所]   # 既定は ../makoto-scripts
#
# 何も出なければ書くものは無い。正本の手順は makoto-scripts の README「誕生日の原稿は、使ったら次を書く」。
set -u
dir=${1:-../makoto-scripts}
file="$dir/drafts/birthday.yaml"
[ -f "$file" ] || file="$dir/birthday.yaml"
[ -f "$file" ] || { echo "⚠ 誕生日の原稿が見つからない（$dir）。README のパスを確かめる"; exit 1; }
ruby -ryaml -rdate -e '
  rows = YAML.safe_load_file(ARGV[0], permitted_classes: [Date])
  rows.select { _1["slug"].to_s.start_with?("birthday-friend-") && _1["date"].to_s =~ /\A\d{4}-/ }
    .group_by { _1["date"].to_s[5..] }
    .each { |day, list| last = list.map { Date.parse(_1["date"].to_s) }.max
      puts "#{day}: 次を書く（最後は #{last}）" if last < Date.today }
' "$file"
