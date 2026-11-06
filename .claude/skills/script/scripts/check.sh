#!/usr/bin/env bash
# makoto-scripts の原稿を機械で検査し、本数を数える（#540）。⚠ 読むだけ。
#
#   .claude/skills/script/scripts/check.sh [makoto-scripts の場所] [比べる版]
#     # 既定は ../makoto-scripts と origin/main
#
# - 全体: slug が全部の行にあり、直下の YAML をまたいで重ならないこと（取り込みが弾く形）
# - 足した行（比べる版に無い slug）: 書き方の決まりのうち、語で拾えるもの
#   ⚠ 語で拾えるのは一部だけ。拾えなかったものが「決まりを満たした」ではない（中身は人が読む）
# - 本数: type ごとの本数と、朝挨拶の通年の本数（＝ 一周の日数）。⚠ 比べる版との差も出す
#
# 終了コード: ✗ が 1 つでもあれば 1（⚠ は 0。⚠ は人が読んで決める）
set -u
dir=${1:-../makoto-scripts}
base=${2:-origin/main}
[ -e "$dir/.git" ] || { echo "✗ makoto-scripts が見つからない（$dir）"; exit 1; }
cd "$dir" || exit 1
git rev-parse --verify -q "$base" >/dev/null || { echo "✗ 比べる版が無い（$base）。git fetch してから"; exit 1; }
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
for f in *.yaml; do
  git show "$base:$f" >"$tmp/$f" 2>/dev/null || : >"$tmp/$f"
done

ruby -ryaml -rdate - "$tmp" ./*.yaml <<'RUBY'
base_dir, *files = ARGV
load = ->(path) { File.zero?(path) ? [] : (YAML.safe_load_file(path, permitted_classes: [Date]) || []) }
rows = files.flat_map { |f| load.(f).map { _1.merge('_file' => f) } }
base = files.flat_map { |f| load.(File.join(base_dir, f)) }
errors = 0
warns = 0
err = ->(msg) { errors += 1; puts "✗ #{msg}" }
warn = ->(msg) { warns += 1; puts "⚠ #{msg}" }

rows.reject { _1['slug'] }.each { err.("slug が無い（#{_1['_file']}・#{_1['body'].to_s[0, 20]}…）") }
rows.group_by { _1['slug'] }.select { |k, v| k && v.size > 1 }
  .each { |slug, v| err.("slug が重なっている: #{slug}（#{v.map { _1['_file'] }.uniq.join(', ')}）") }
rows.group_by { _1['type'] }.each do |type, v|
  next if v.map { _1['_file'] }.uniq.size == 1
  err.("type #{type} が 2 つのファイルに分かれている（--prune で片方が消える）")
end

# 書き方の決まりのうち、語で拾えるもの。正本は各ファイルの冒頭のコメントと docs/makoto-persona.md
rules = [
  [//, /わたし/, '一人称は「私」（2026-10-20）'],
  [//, /心を(込|こ)めて|こころを込めて/, '「こころをこめて」はひらがな（自作詞の曲の題名・2026-10-01）'],
  [//, /[？?]\s*\z/, '答えを待つ問いにしない（MAKOTO はまだ応答しない・#18）'],
  [//, /主役|脇役|後ろ|陰で|裏方|支え|背景|目立たない|聴き流し/, '作り手に上下のニュアンスを付けない（2026-09-28）'],
  [/\Amorning\z/, /おはよう/, '定型挨拶はコードが付ける（morning には書かない）'],
  [/\Asong\z/, /歌|曲|音楽|口ずさ/, '共通の前置きは歌の無い曲・ドラマにも付く'],
  [/\Asong/, /朝|昼|夜|夕方|春|夏|秋|冬|月曜|火曜|水曜|木曜|金曜|土曜|日曜/, '前置きは時刻・季節・曜日を言わない'],
  [/\Asong_vocal\z/, /お借りした|カバー/, '「お借りした」「カバー」はライブの言葉'],
  [/\Asong_inst\z/, /抜い|足りない|主旋律|伴奏|骨組み/, 'カラオケ・インストを「欠けたもの」として書かない'],
]
known = base.map { _1['slug'] }.to_set
added = rows.reject { known.include?(_1['slug']) }
added.each do |row|
  type = row['type'].to_s
  body = row['body'].to_s
  rules.each do |types, word, why|
    next unless types.match?(type) && word.match?(body)
    warn.("#{row['slug']}: #{why} — 「#{body.lines.first.strip[0, 30]}」")
  end
  season = Array(row['season'])
  err.("#{row['slug']}: 新しく書く原稿は 1 原稿 1 月（season: #{season.inspect}）") if season.size > 1
  if row['date'] && row['season']
    warn.("#{row['slug']}: date と season の両方がある")
  end
  date = row['date'].to_s
  if date != '' && date !~ /\A(\d{4}-)?\d{2}-\d{2}\z/
    err.("#{row['slug']}: date は MM-DD（毎年）か YYYY-MM-DD（その年だけ）（#{date}）")
  end
end

count = ->(list) { list.group_by { _1['type'] }.transform_values(&:size) }
year_round = ->(list) { list.count { _1['type'] == 'morning' && !_1['season'] && !_1['date'] } }
now = count.(rows)
was = count.(base)
puts
puts "足した行: #{added.size} 本（消えた行: #{(base.map { _1['slug'] } - rows.map { _1['slug'] }).size} 本）"
(now.keys | was.keys).sort_by(&:to_s).each do |type|
  a = was.fetch(type, 0)
  b = now.fetch(type, 0)
  puts format('  %-14s %4d%s', type, b, a == b ? '' : "（#{a} → #{b}）")
end
a = year_round.(base)
b = year_round.(rows)
puts "朝挨拶の通年: #{b} 本#{a == b ? '' : "（#{a} → #{b}）"} ＝ 一周の日数#{b < 366 ? ' ⚠ 366 を割っている' : ''}"
puts
puts(errors.zero? ? "✗ 0 件・⚠ #{warns} 件（⚠ は人が読んで決める）" : "✗ #{errors} 件・⚠ #{warns} 件")
exit(errors.zero? ? 0 : 1)
RUBY
