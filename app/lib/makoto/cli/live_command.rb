module Makoto
  # バースデーライブ（#13）の下見。⚠ **投稿はしない。**
  #
  # ⚠⚠ **8 時間 160 枠を目視で確認するための口。**#13 の完了条件は「日付を差し替えた
  # リハーサルをステージングで通し、8 時間分の進行が破綻しないことを確認」なので、
  # **実際に 8 時間流す前に並びを読めること**が要る。
  class LiveCommand < Thor
    include Package

    def self.exit_on_failure?
      return true
    end

    option :date, type: :string, desc: '下見する日付（既定は今日）。YYYY-MM-DD'
    option :limit, type: :numeric, desc: '表示する枠の数（既定は全部）'
    option :mc, type: :boolean, default: false, desc: 'MC の原稿の本文も表示する'
    desc 'setlist', 'その日の並び（曲・カバー・MC）を表示する'
    def setlist
      @live = Live.new
      timetable = @live.timetable
      date = preview_date(options[:date])
      dump(Setlist.new(date: date, slots: timetable.size(date)), timetable, date)
    rescue Ginseng::ValidateError, Ginseng::ConfigError => e
      warn error_message(e)
      exit 1
    rescue Sequel::DatabaseError => e
      warn '読めませんでした。先に `rake migration:run` と' \
        " `makoto track import` を実行してください: #{error_message(e)}"
      exit 1
    end

    desc 'slots', '4 つの枠（前日増量・開始告知・進行・終了告知）を表示する'
    def slots
      live = Live.new
      live.jobs.each do |job|
        puts "#{job.name}: #{job.timetable}"
      end
      puts "台本の type: #{live.types.join(', ')}"
    rescue Ginseng::ConfigError => e
      warn error_message(e)
      exit 1
    end

    private

    def dump(list, timetable, date)
      times = timetable.times(date)
      puts "#{date} #{timetable} / #{list.size} 枠"
      puts "本編 #{list.songs.size} 曲 / カバー #{list.covers.size} 曲"
      puts mc_summary(list, times.first)
      list.entries.first(options[:limit] || list.size).each_with_index do |entry, index|
        at = times[index]
        puts "#{at&.strftime('%H:%M') || '--:--'} [#{index}] #{label(entry, at)}"
      end
    end

    # ⚠⚠ **MC は本番でいちばん本数の出る要素なのに、圧縮リハーサルでは構造的に
    # 出ない**（埋め草は `枠数 − 曲数 − アンカー`）。⚠ **下見で本数と繰り返しを
    # 読めるようにしておく**（→ #62）。
    def mc_summary(list, time)
      slots = list.entries.count(&:mc?)
      scripts = mc_size(time)
      return "MC #{slots} 枠 / 原稿 #{scripts} 本" if scripts.zero? || slots <= scripts
      return "MC #{slots} 枠 / 原稿 #{scripts} 本（⚠ #{slots - scripts} 本が 2 回出る）"
    end

    # ⚠ **MC の本文は `LiveProgram` から引く。**「何本目がどの原稿か」の正本を
    # 下見の側に写さない（写すと下見と実際の投稿が食い違いうる）。
    def label(entry, time)
      return entry.to_s unless entry.mc? && options[:mc]
      body = @live.program.mc_text(entry, time)
      return "#{entry}: （原稿が無いので投稿しない）" if body.blank?
      return "#{entry}:#{repeat_mark(entry, time)} #{body.lines.first.to_s.chomp}"
    end

    # ⚠ 同じ原稿が 2 回目に出る枠を目で拾えるようにする。⚠⚠ **原稿は進行の割合で
    # 引く**ので（#69）、**続けて同じものが出るのが 2 回目の形**。前から数える。
    def repeat_mark(entry, time)
      scripts = mc_size(time)
      return '' if scripts.zero?
      @used ||= Hash.new(0)
      index = @live.program.script_index(entry, scripts)
      @used[index] += 1
      return '' if @used[index] < 2
      return " ↻#{@used[index]}回目"
    end

    def mc_size(time)
      @mc_size ||= @live.program.mc_size(time)
      return @mc_size
    end

    # ⚠⚠ **日付のまま渡す。**時刻を作るとホストの TZ で解釈され、日本の外で
    # 下見すると 11/4 が 11/5 になる（→ MessageCommand と同じ理由）。
    def preview_date(value)
      return Date.today if value.blank?
      return Date.parse(value)
    rescue Date::Error
      raise Ginseng::ValidateError, "日付は YYYY-MM-DD で指定してください（'#{value}'）"
    end
  end
end
