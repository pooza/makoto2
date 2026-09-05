module Makoto
  # 朝挨拶（#17）の下見。⚠ **投稿はしない。**
  #
  # ⚠⚠ **#17 の完了条件は「連日で同じ挨拶が続かない」「上書き原稿がある日はそちらが
  # 出る」**の 2 つで、🔴 **どちらも 1 日 1 本の枠なので、実機で確かめるには何日も
  # 待つことになる。**⚠ **日付を渡して先の日を読めるようにしておく**（→ `LiveCommand`
  # と同じ考え方。**8 時間流す前に並びを読めること**）。
  class MorningCommand < Thor
    include Package

    # 既定で見る日数。⚠ 1 週間ぶんあれば「連日で同じ挨拶が続かない」は目視できる。
    DEFAULT_DAYS = 7

    def self.exit_on_failure?
      return true
    end

    option :date, type: :string, desc: '下見を始める日付（既定は今日）。YYYY-MM-DD'
    option :days, type: :numeric, default: DEFAULT_DAYS, desc: '表示する日数'
    desc 'preview', '朝挨拶を数日ぶん表示する（投稿はしない）'
    def preview
      days = options[:days].to_i
      raise Ginseng::ValidateError, "日数は 1 以上で指定してください（#{days}）" unless days.positive?
      dump(start_date(options[:date]), days)
    rescue Ginseng::ValidateError, Ginseng::ConfigError => e
      warn error_message(e)
      exit 1
    rescue Sequel::DatabaseError => e
      warn '読めませんでした。先に `rake migration:run` と' \
        " `makoto corpus import` を実行してください: #{error_message(e)}"
      exit 1
    end

    desc 'slot', '枠・原稿の本数・一周の長さを表示する'
    def slot
      job = morning.job
      puts "#{job.name}: #{job.timetable}"
      puts "原稿の type: #{morning.types.join(', ')}（定型挨拶が付くのは #{morning.type}）"
      puts "実況の窓: #{CommentaryWindow.new}"
      dump_cycle
      dump_seasons
    rescue Ginseng::ConfigError => e
      warn error_message(e)
      exit 1
    rescue Sequel::DatabaseError => e
      warn "読めませんでした。先に `rake migration:run` を実行してください: #{error_message(e)}"
      exit 1
    end

    private

    # 🔴 **一周の長さ ＝ 通年の原稿の本数**（#223 / #225）。⚠⚠ **同じ挨拶が戻るまでの
    # 間隔は、その半分を下回らない**（前半・後半を保ったまま組み替えるため）。
    # ⚠ **「少しずつ増やす」の進捗がここに出る**（目標は一周 365 日超）。
    def dump_cycle
      size = morning.selector.undated_list(today).size
      if size.zero?
        puts '通年の原稿: 0 本（⚠ 日替わりの原稿がありません）'
        return nil
      end
      puts "通年の原稿: #{size} 本（一周 #{size} 日・同じ原稿が戻るのは最短 #{size / 2} 日）"
      return nil
    end

    # ⚠ **月別の件数。**🔴 **穴がそのまま見える**（実データは 5 月が 1 本）。
    def dump_seasons
      counts = (1..12).map do |month|
        morning.selector.season_list(Date.new(today.year, month, 1)).size
      end
      puts "季節の原稿: #{counts.sum} 本（延べ）"
      puts counts.map.with_index(1) {|size, month| "#{month}月#{size}"}.join(' ')
      return nil
    end

    def today
      return MessageSelector.new([morning.type]).date_of(Time.now)
    end

    # ⚠ テストが差し替えるためだけに 1 つに寄せてある（→ `LiveCommand#setlist`）。
    def morning
      @morning ||= Morning.new
      return @morning
    end

    def dump(date, days)
      days.times do |offset|
        day = date + offset
        record = morning.source.find(day)
        puts "#{day} (#{Date::ABBR_DAYNAMES[day.wday]})"
        # ⚠ **原稿が無い日は投稿そのものが起きない**（黙って空行を出さない）。
        next puts('  原稿はありません（投稿しません）') unless record
        puts "  [#{record[:id]}] #{record[:type]}"
        morning.source.call(day).each_line {|line| puts "  #{line.chomp}"}
      end
    end

    # ⚠⚠ **ホストの TZ ではなく `/scheduler/timezone` で「今日」を出す。**
    # ⚠ **規則の正本は `MessageSelector#date_of`**（`Date.today` を書かない）。
    def start_date(value)
      date = ScriptImporter.parse_preview_date(value)
      return date if date
      return MessageSelector.new([morning.type]).date_of(Time.now)
    end
  end
end
