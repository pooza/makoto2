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
    option :body, type: :boolean, default: false,
      desc: '実際に投稿される本文を丸ごと表示する（--limit と併用する）'
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
        dump_body(at) if options[:body]
      end
    end

    # 実際に投稿される本文（#159）。
    #
    # 🔴 **1 行の要約では見えないものがある** — **カバーの断り文とその後ろの 1 行アキ
    # （#122）・URL の行・ハッシュタグの行（#64）・MC の 2 行目以降。**
    # ⚠⚠ **#158（断り文が 8 回出て MC 宣言と重複する）は、ここを並べて初めて見えた。**
    #
    # ⚠ **ログにも本文は出ない**（`length` だけ）ので、⚠⚠ **投稿を読み返すには
    # `read:statuses` が要る** — **トークンのスコープに無く、発行後に変更できない。**
    # 🔴 **「当日どう見えるか」を安く確かめられる唯一の口。**
    def dump_body(time)
      body = source.call(time).to_s
      puts body.empty? ? '（投稿しない）' : body
      puts
    end

    # ⚠⚠ **`Live#tagged` を通す。**🔴 **ハッシュタグを足すのは `HashtagSource`** なので、
    # ⚠ **`LiveProgram` を直に呼ぶと最終行が落ちて、また下見と投稿が食い違う**（#62）。
    def source
      @source ||= @live.tagged(@live.program)
      return @source
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

    # ⚠ **本文は `LiveProgram` から引く。**「何がどう出るか」の正本を下見の側に
    # 写さない（写すと下見と実際の投稿が食い違いうる）。
    def label(entry, time)
      return song_label(entry) unless entry.mc?
      return entry.to_s unless options[:mc]
      body = @live.program.mc_text(entry, time)
      return "#{entry}: （原稿が無いので投稿しない）" if body.blank?
      return "#{entry}:#{repeat_mark(entry, time)} #{body.lines.first.to_s.chomp}"
    end

    # 曲とカバーの 1 行。⚠⚠ **実際に投稿される見え方で出す**（#119 / #120 / #121）。
    #
    # 🔴 **`Entry#to_s` の素の曲名・名義を出さない** — ⚠ **括弧書きを落とし、自分名義を
    # 隠すのはライブの都合**なので、**下見が素のまま出すと「当日どう見えるか」を
    # 下見で確かめられない**（→ #62 の「下見と実際の投稿が食い違うと信用できない」）。
    def song_label(entry)
      presenter = @live.program.track_presenter(entry)
      label = entry.cover? ? 'カバー' : '曲'
      return "#{label}: #{presenter.name}" if presenter.credit.blank?
      return "#{label}: #{presenter.name} / #{presenter.credit}"
    end

    # ⚠ 同じ原稿が 2 回目に出る枠を目で拾えるようにする。⚠⚠ **原稿は進行の割合で
    # 引く**ので（#69）、**続けて同じものが出るのが 2 回目の形**。前から数える。
    def repeat_mark(entry, time)
      scripts = mc_scripts(time)
      return '' if scripts.empty?
      @used ||= Hash.new(0)
      index = @live.program.script_index(entry, scripts)
      @used[index] += 1
      return '' if @used[index] < 2
      return " ↻#{@used[index]}回目"
    end

    # ⚠ 1 回だけ引く（160 枠ぶん引き直さない）。
    def mc_scripts(time)
      @mc_scripts ||= @live.program.mc_scripts(time)
      return @mc_scripts
    end

    def mc_size(time)
      return mc_scripts(time).size
    end

    # ⚠⚠ **日付のまま渡す。**時刻を作るとホストの TZ で解釈され、日本の外で
    # 下見すると 11/4 が 11/5 になる（→ MessageCommand と同じ理由）。
    # ⚠⚠ **規則の正本は `ScriptImporter.parse_date`**（#96）。🔴 **`Date.parse` に戻さない** —
    # **`11-4` が 8 月 11 日になり、エラーにならずそれらしい並びが出る。**
    # ⚠ **下見はライブの日付そのものに対する唯一の防御**（→ docs/CLAUDE.md）。
    def preview_date(value)
      return ScriptImporter.parse_preview_date(value) || Date.today
    end
  end
end
