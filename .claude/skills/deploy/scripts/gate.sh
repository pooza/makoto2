#!/usr/bin/env bash
# 時刻の門（release 9. / deploy 2.）。対象のホストの設定から「自分から出す枠」の頭を出し、
# いまから先の窓に枠の頭・実況の時間・凍結の期間が入っていないかを見る。⚠ 読むだけ。
#
#   .claude/skills/deploy/scripts/gate.sh <ホスト> [分]   # 分は作業にかける見込み（既定 15）
#
# 🔴 枠の数字をここに焼かない。正本は設定（bin/makoto config の timetable）で、毎回ホストから引く
#    （#279・08:00:30 だけが焼かれて曲紹介の枠に連動しなかった）。
# ⚠ ライブの枠（/live/*）は 11/3・11/4 にしか投稿しないので平常日は数えない。11/1〜11/4 は
#    インフラの凍結なので、そもそも門を通さない（docs/CLAUDE.md「デプロイ・運用」）。
set -u
host=${1:?ホストを指定する（bydo / rubicon）}
minutes=${2:-15}
config=$(ssh -o ConnectTimeout=10 "$host" 'sudo -u deploy -i bash -c "cd ~/repos/makoto2 && bin/makoto config"' 2>/dev/null)
if ! echo "$config" | grep -q timetable; then
  echo "⚠ $host から timetable が読めない（VPN・常駐の設定を確かめる）"
  exit 1
fi
# ⚠ GATE_NOW（epoch 秒）で「いま」を差し替えられる（門そのものを確かめるときだけ）。
now=${GATE_NOW:-$(ssh -o ConnectTimeout=10 "$host" 'date +%s')}
# 🔴 **時刻が取れなければ落とす**（v0.9.0 のリリース前レビューの黄）。⚠⚠ 空のままだと「いま」が
# 1970-01-01 になり、凍結・実況の窓・枠の頭のどれにも当たらず門が開いていた。
if ! [[ "$now" =~ ^[0-9]+$ ]] || [ "$now" -lt 1000000000 ]; then
  echo "⚠ $host の時刻が読めない（'$now'）。門を判定できない"
  exit 1
fi
# shellcheck disable=SC2016 # ruby のコードなので展開しない
CONFIG="$config" NOW="$now" MINUTES="$minutes" HOST="$host" ruby -e '
  require "time"
  require "yaml"
  ENV["TZ"] = "Asia/Tokyo"
  tolerance = 30
  now = Time.at(ENV["NOW"].to_i)
  until_t = now + ENV["MINUTES"].to_i * 60
  live_day = [[11, 3], [11, 4]].include?([now.month, now.day])
  table = Hash.new { |h, k| h[k] = {} }
  ENV["CONFIG"].each_line do |line|
    next unless line.include?("/timetable/")
    next unless line =~ %r{"/(.+)/timetable/(start|finish|interval)":\s*\x27?([^\x27\s]+)}
    table[$1][$2] = $3
  end
  seconds = ->(v) { v.scan(/(\d+)([hms])/).sum { |n, u| n.to_i * {"h" => 3600, "m" => 60, "s" => 1}[u] } }
  at = ->(day, hm) { h, m = hm.split(":").map(&:to_i); Time.new(day.year, day.month, day.day, h, m, 0) }
  heads = []
  table.each do |name, t|
    next if name.start_with?("live") && !live_day
    [now, now + 86_400].each do |day|
      head = at.call(day, t["start"])
      finish = at.call(day, t["finish"])
      while head < finish
        heads << [head, name]
        head += seconds.call(t["interval"])
      end
    end
  end
  bad = []
  # ⚠ 端の時刻だけでなく、窓全体が禁止の期間と重なるかを見る（窓が期間をまるごと含む形を通さない）。
  overlap = ->(from, to) { now < to && from <= until_t }
  [now.year, until_t.year].uniq.each do |year|
    if overlap.call(Time.new(year, 11, 1), Time.new(year, 11, 5))
      bad << "11/1〜11/4 はインフラの凍結（rubicon に触らない）"
    end
  end
  # 🔴 強い窓（実況の時間）は設定の /commentary/windows から引く（#561）。⚠ 日曜 08:30〜09:00 を焼かない。
  # ⚠ 読めなければ門を開けない（窓が空のまま通すと、実況の時間に本番を止めうる）。
  if ENV["HOST"] == "rubicon"
    windows = begin
      Array(YAML.safe_load(ENV["CONFIG"])["/commentary/windows"])
    rescue => e
      warn "⚠ /commentary/windows が読めない（#{e.class}）。門を判定できない"
      exit 1
    end
    strong = windows.select { |w| w["strength"] == "strong" }
    if strong.empty?
      warn "⚠ /commentary/windows に強い窓が無い。門を判定できない"
      exit 1
    end
    day = Time.new(now.year, now.month, now.day)
    while day <= until_t
      strong.each do |w|
        next if w["weekdays"] && !w["weekdays"].include?(day.wday)
        if overlap.call(at.call(day, w["start"]), at.call(day, w["finish"]))
          bad << "#{w["start"]}〜#{w["finish"]} は実況の時間（#{w["name"]}・#{day.strftime("%m-%d %a")}）"
        end
      end
      day += 86_400
    end
  end
  inside = heads.select { |head, _| head <= until_t && head + tolerance >= now }.sort
  inside.each { |head, name| bad << "枠の頭 #{head.strftime("%m-%d %H:%M")}（#{name}）が窓の内側" }
  nxt = heads.select { |head, _| head > now }.min
  puts "いま #{now.strftime("%Y-%m-%d %H:%M:%S %a")} / 窓 #{ENV["MINUTES"]} 分（〜#{until_t.strftime("%H:%M")}）"
  puts "次の枠: #{nxt[0].strftime("%m-%d %H:%M")}（#{nxt[1]}）" if nxt
  if bad.empty?
    puts "✅ 門を通る（レシピと restart の間に枠の頭が入らない）"
  else
    bad.each { |b| puts "🔴 #{b}" }
    exit 1
  end
'
