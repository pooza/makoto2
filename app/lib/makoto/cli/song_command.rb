module Makoto
  # 曲紹介（#16）の下見。⚠ **投稿はしない。**
  #
  # ⚠⚠ **曲は抽選なので、下見は「次に何が出るか」を言い当てられない。**
  # 🔴 **前置きは順送りだが、候補は引いた曲の `kind` で変わる**（#293 → `SongSource`）。
  # ⚠ **したがってここが見せるのは 2 つ** — **前置きの本数（`kind` ごと）**と、
  # **`kind` ごとに実際に組んだ本文。**
  #
  # 🔴 **#16 の完了条件は「紹介文が `kind` に応じて破綻しないこと」**なので、
  # ⚠⚠ **`--kind` で 1 つずつ当てられるようにしてある。**
  class SongCommand < Thor
    include Package

    # 既定で見る日数。⚠ 1 週間ぶんあれば「連日で同じ前置きが続かない」は目視できる。
    DEFAULT_DAYS = 7

    # `song sample --pool` の値（#314 → `SongSource#prefix_record`）。
    POOLS = ['auto', 'own', 'common'].freeze

    def self.exit_on_failure?
      return true
    end

    option :date, type: :string, desc: '下見を始める日付（既定は今日）。YYYY-MM-DD'
    option :days, type: :numeric, default: DEFAULT_DAYS, desc: '表示する日数'
    desc 'preview', '曲紹介を数日ぶん組んで表示する（投稿はしない）'
    def preview
      days = options[:days].to_i
      raise Ginseng::ValidateError, "日数は 1 以上で指定してください（#{days}）" unless days.positive?
      dump(start_date(options[:date]), days)
    rescue Ginseng::ValidateError, Ginseng::ConfigError => e
      warn error_message(e)
      exit 1
    rescue Sequel::DatabaseError => e
      warn '読めませんでした。先に `rake migration:run` と' \
        " `makoto track import` を実行してください: #{error_message(e)}"
      exit 1
    end

    option :kind, type: :string, desc: '見る kind（既定は全部）'
    option :count, type: :numeric, default: 1, desc: 'kind ごとの本数'
    option :pool, type: :string, default: 'auto', enum: POOLS,
      desc: '前置きの束（auto = 実機と同じ決め方 / own = 種類別 / common = 共通）'
    desc 'sample', 'kind ごとに本文を組んで表示する（投稿はしない）'
    def sample
      count = options[:count].to_i
      raise Ginseng::ValidateError, "本数は 1 以上で指定してください（#{count}）" unless count.positive?
      dump_samples(kinds(options[:kind]), count, pool_option(options[:pool]))
    rescue Ginseng::ValidateError, Ginseng::ConfigError => e
      warn error_message(e)
      exit 1
    rescue Sequel::DatabaseError => e
      warn '読めませんでした。先に `rake migration:run` と' \
        " `makoto track import` を実行してください: #{error_message(e)}"
      exit 1
    end

    desc 'slot', '枠・前置きの本数・抽選の母集合を表示する'
    def slot
      SongSlotPresenter.new(song, repository).print
    rescue Ginseng::ConfigError => e
      warn error_message(e)
      exit 1
    rescue Sequel::DatabaseError => e
      warn "読めませんでした。先に `rake migration:run` を実行してください: #{error_message(e)}"
      exit 1
    end

    private

    # 🔴 **語りの表が読めないことを下見の頭で言う**（#314）。⚠⚠ **読めないと全枠が「（bgm・語り）」の
    # ように出るが、理由の `warn` は syslog にしか出ない**（`song slot` だけが理由を出していた）。
    #
    # ⚠ **`keys` まで引く**（PR #475 の Codex の P2）。🔴 **`names` は別名表を読まない**ので、**語りの表は
    # 読めて別名表が壊れているとき、実機（`SongSource#spoken?` は `keys` を通る）は全部を共通に倒すのに、
    # 下見は何も言わなかった。**
    #
    # ⚠ **読めたかを返す**（`song sample` のラベルが「語りのトラックなので」と名乗ってよいか）。
    def dump_spoken_failure
      song.spoken_tracks.keys
      return true
    rescue => e
      puts "🔴 語りの表を読めません（⚠ 全部の曲を共通だけにします）: #{error_message(e)}"
      return false
    end

    def kinds(value)
      available = repository.count_by_kind(song.lottery.candidates).keys.map(&:to_s).sort
      return available unless value
      unless available.include?(value.to_s)
        raise Ginseng::ValidateError,
          "kind '#{value}' の曲がありません（#{available.join(', ')}）"
      end
      return [value.to_s]
    end

    # 🔴 **`kind` ごとに実際に本文を組む**（#16 の完了条件）。⚠ **前置きは今日の
    # 1 本目のものを使う**（**本文の形を見るのが目的**なので、順送りは動かさない）。
    # ⚠ **前置きはその `kind` の束から引く**（#293）。⚠ **語りのトラックは共通から**（#298）。
    #
    # 🔴 **どの束のどの原稿を使ったかを出す**（#314）。⚠⚠ **今日の 1 本目が共通を引く日は、`--kind=bgm`
    # でも種類別の文面を確かめられなかった** — ⚠ **`--pool=own` で束を指定できる。**
    #
    # 🔴 **語りの表が読めなければ頭でそう言う**（v0.8.0 のリリース前レビュー）。⚠⚠ **読めないと全曲が
    # 共通に倒れる**（`SongSource#spoken?`）のに、**ラベルは「語りのトラックなので」と誤った理由を名乗り、
    # `--pool=own` も黙って効かなかった**（`preview` だけ #314 で直していた）。
    def dump_samples(names, count, pool)
      @spoken_readable = dump_spoken_failure
      names.each do |kind|
        puts "=== #{kind} ==="
        song.lottery.candidates.where(kind: kind).order(Sequel.lit('RANDOM()'))
          .limit(count).each {|track| dump_sample(track, kind, pool)}
      end
      return nil
    end

    def dump_sample(track, kind, pool)
      spoken = song.source.spoken?(track)
      record = song.source.prefix_record(first_slot,
        kind: spoken ? nil : kind, bundle: spoken ? :common : pool)
      puts "  #{sample_label(record, spoken)}"
      text = song.source.presenter(track, record && record[:body]).to_s
      puts text.each_line.map {|line| "  #{line}"}.join
      puts
    end

    # ⚠ **どの束から引いたか。**🔴 **種類別を指定して 0 本なら、そう書く**（曲だけになる）。
    def sample_label(record, spoken)
      return '（前置きはありません）' unless record
      bundle = record[:type] == song.type ? '共通' : '種類別'
      # ⚠ **表が読めずに倒れたときは「語りのトラック」と名乗らない**（理由は頭の 1 行が言う）。
      bundle = "#{bundle}・#{@spoken_readable == false ? '語りの表が読めないので' : '語りのトラックなので'}共通" if spoken
      return "[#{record[:id]}] #{record[:type]}（#{bundle}）"
    end

    # `--pool` の値を `SongSource#prefix_record` の引数に。⚠ `auto` は実機と同じ決め方（`nil`）。
    def pool_option(value)
      return nil if value.nil? || value.to_s == 'auto'
      return value.to_sym
    end

    # 🔴 **黙る日はそう書く**（Codex の P1）。⚠⚠ **枠だけを並べると、下見と実機が
    # 食い違う** — ⚠ **11/3 / 11/4 はライブが持っているので 1 通も出ない。**
    def dump(date, days)
      dump_spoken_failure
      days.times do |offset|
        day = date + offset
        puts "#{day} (#{Date::ABBR_DAYNAMES[day.wday]})"
        next puts("  #{quiet_reason(day)}") if song.source.quiet?(day)
        song.timetable.times(day).each {|time| dump_slot(time)}
      end
    end

    # ⚠⚠ **曲は抽選なので、下見と実機は一致しない。**⚠ **形を見るためのもの。**
    # 🔴 **前置きは引いた曲の `kind` で決まる**（#293）ので、**曲を引いてから書く。**
    def dump_slot(time)
      clock = time.strftime('%H:%M')
      entry = song.source.compose(time)
      return puts("  #{clock} （曲を引けませんでした）") unless entry
      record = entry[:prefix]
      label = record ? "[#{record[:id]}] #{record[:type]}" : '前置きはありません'
      # ⚠ **語りのトラックはそう書く**（#298）。**種類が `vocal` なのに共通が付く理由**。
      kind = entry[:spoken] ? "#{entry[:track][:kind]}・語り" : entry[:track][:kind]
      puts "  #{clock} #{label}（#{kind}）"
      entry[:text].each_line {|line| puts "    #{line.chomp}"}
      return nil
    end

    # ⚠ **どの枠が持っている日かを名指しで書く**（**「出ません」だけだと理由が追えない**）。
    def quiet_reason(day)
      types = song.selector.reserved_types_on(day) & song.quiet_types
      return "他の枠が持つ日なので出しません（#{types.join(', ')}）"
    end

    # その日の 1 本目の枠。⚠ **枠の番号が要る**ので時刻で渡す（`Date` では出ない）。
    def first_slot
      return song.timetable.times(today).first
    end

    def repository
      @repository ||= TrackRepository.new
      return @repository
    end

    # ⚠ テストが差し替えるためだけに 1 つに寄せてある（→ `MorningCommand#morning`）。
    def song
      @song ||= Song.new
      return @song
    end

    # ⚠⚠ **ホストの TZ ではなく `/scheduler/timezone` で「今日」を出す。**
    # ⚠ **規則の正本は `MessageSelector#date_of`**（`Date.today` を書かない）。
    def today
      return song.selector.date_of(Time.now)
    end

    def start_date(value)
      date = ScriptImporter.parse_preview_date(value)
      return date || today
    end
  end
end
