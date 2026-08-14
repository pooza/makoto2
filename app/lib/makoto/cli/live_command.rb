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
    desc 'setlist', 'その日の並び（曲・カバー・MC）を表示する'
    def setlist
      timetable = Live.new.timetable
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
      list.entries.first(options[:limit] || list.size).each_with_index do |entry, index|
        puts "#{times[index]&.strftime('%H:%M') || '--:--'} [#{index}] #{entry}"
      end
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
