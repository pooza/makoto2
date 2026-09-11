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
    desc 'sample', 'kind ごとに本文を組んで表示する（投稿はしない）'
    def sample
      count = options[:count].to_i
      raise Ginseng::ValidateError, "本数は 1 以上で指定してください（#{count}）" unless count.positive?
      dump_samples(kinds(options[:kind]), count)
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
      job = song.job
      puts "#{job.name}: #{job.timetable}"
      puts "1 日 #{job.timetable.size(today)} 本（#{job.timetable.times(today).map do |time|
        time.strftime('%H:%M')
      end.join(' / ')}）"
      puts "実況の窓: #{CommentaryWindow.new}"
      dump_quiet_days
      dump_prefixes
      dump_spoken
      dump_history
      dump_pool
    rescue Ginseng::ConfigError => e
      warn error_message(e)
      exit 1
    rescue Sequel::DatabaseError => e
      warn "読めませんでした。先に `rake migration:run` を実行してください: #{error_message(e)}"
      exit 1
    end

    private

    # 🔴 **ライブが持つ日は黙る**（Codex の P1）。⚠⚠ **設定を消すと黙らなくなる**ので、
    # ⚠ **「いま何日が黙る日か」がここに出る。**
    def dump_quiet_days
      types = song.quiet_types
      if types.empty?
        puts '黙る日: 無し（⚠ ライブの日も日常の曲を出します）'
        return nil
      end
      days = song.selector.anniversary_types.select {|_, names| names.intersect?(types)}.keys
      puts "黙る日: #{days.sort.join(' / ')}（#{types.join(', ')}）"
      return nil
    end

    # 🔴 **一周の長さ ＝ 前置きの本数 ÷ 1 日の本数**（#223 の規則を通す）。
    # ⚠⚠ **同じ前置きが戻るまでの間隔は、その半分を下回らない。**
    #
    # 🔴 **`kind` ごとに候補の束が違う**（#293）ので、**束ごとに 1 行ずつ出す。**
    # ⚠ **束は種類別だけ**（共通は混ぜない → `Song#kind_selectors`）。
    def dump_prefixes
      slots = song.timetable.size(today)
      common = song.selector.list(today).size
      groups = prefix_groups
      # 🔴 **種類別が 1 本でもあれば、共通も毎枠は引かれない**（→ `SongSource#pool`）。
      exact = groups.keys.all? {|name| type_size(name).zero?}
      return puts('前置きの原稿: 0 本（⚠ 曲だけを出します）') if common.zero? && exact
      note = common.zero? ? '⚠ 種類別の無い kind は曲だけ' : cycle_note(common, slots, exact:)
      puts "前置きの原稿: 共通 #{common} 本（#{song.type}・#{note}）"
      groups.each {|name, kinds| puts group_line(name, kinds, slots)}
      return nil
    end

    # `{type => [kind, ...]}`。⚠ **複数の `kind` が同じ type を指す**ので、束ねて 1 行にする。
    def prefix_groups
      return song.kind_types.group_by(&:last).transform_values {|pairs| pairs.map(&:first)}
    end

    # ⚠ **束 1 つぶん。**🔴 **種類別が 0 本なら、そう書く**（**共通だけで回っている**）。
    #
    # ⚠ **種類別の束は「その種類の曲が出た枠の、さらに一部」でしか引かれない**
    # （→ `SongSource#pool`）ので、**一周の日数は出せない。下限だけを出す**（Codex の P2）。
    def group_line(name, kinds, slots)
      own = type_size(name)
      label = "  #{kinds.join(' / ')}: #{name} #{own} 本"
      return "#{label}（⚠ 共通だけ）" if own.zero?
      return "#{label}（共通と本数の比で引き分け・#{cycle_note(own, slots, exact: false)}）"
    end

    # 🔴 **語りのトラック**（#298 → `SpokenTracks`）。⚠ **共通の前置きだけが付く。**
    #
    # ⚠⚠ **母集合に当たらない名前も出す**（書き間違い・配信終了）— 🔴 **当たらない行は
    # 「表に書いたのに効いていない」**ので、**歌向けの前置きが付いていても気づけない。**
    def dump_spoken
      spoken = song.spoken_tracks
      return puts('語りのトラック: 無し') if spoken.empty?
      unused = spoken.unused(song.lottery.candidates.select_map(:dedupe_key).to_set)
      line = "語りのトラック: #{spoken.names.size} 本（共通の前置きだけ）"
      line = "#{line} 🔴 母集合に当たらない: #{unused.join(' / ')}" unless unused.empty?
      puts line
    rescue Ginseng::ValidateError => e
      puts "語りのトラック: 🔴 表を読めません（⚠ 全部の曲を共通だけにします）: #{error_message(e)}"
    end

    # その type だけの本数。
    def type_size(name)
      return song.selector_of([name]).list(today).size
    end

    # 🔴 **「同じ前置きが戻るのは最短 n/2 枠」は、束が毎枠引かれなくても成り立つ**
    # （**通し番号の距離の話**なので、**引かれない枠が挟まるほど間隔は延びるだけ**）。
    #
    # ⚠⚠ **一周の日数は、束が毎枠引かれるときにしか言えない**（Codex の P2）。
    # ⚠ **`exact: false` なら下限だけを出す**（**一周は曲の種類の出方で延びる**）。
    def cycle_note(size, slots, exact: true)
      cycle = ((size.to_f / slots) * 10).round / 10.0
      return "一周 #{cycle} 日・同じ前置きが戻るのは最短 #{cycle / 2} 日" if exact
      return "同じ前置きが戻るのは最短 #{cycle / 2} 日・⚠ 一周は曲の種類の出方で延びる"
    end

    # 🔴 **最近出した曲を避けているか**（#41）。⚠⚠ **設定を消せば止まる**ので、
    # ⚠ **「いま何本ぶん避けているか」がここに出る。**
    #
    # ⚠ **記録が窓に満たないうちは、その本数しか避けていない**（🔴 **入れたその日から
    # 効くわけではない**）。
    def dump_history
      history = song.history
      unless history.enabled?
        puts '最近出した曲を避ける: 無し（⚠ 同じ曲が続けて出ることがあります）'
        return nil
      end
      last = history.last
      when_ = last ? "最後は #{last[:posted_at]}" : '⚠ まだ 1 本も出していません'
      puts "最近出した曲を避ける: #{history}（記録 #{history.count} 本・#{when_}）"
      return nil
    end

    # ⚠ **抽選の母集合。**🔴 **重みは「その kind が選ばれる確率の比」**であって
    # 曲数の割合ではない（→ docs/track-corpus.md）。
    def dump_pool
      counts = repository.count_by_kind(song.lottery.candidates)
      weights = song.lottery.weights
      puts "抽選の母集合: #{counts.values.sum} 曲"
      weights.sort_by {|_, weight| -weight}
        .each {|kind, weight| puts pool_line(kind, weight, counts, weights)}
      return nil
    end

    # ⚠⚠ **出る割合は「重みの合計」に対する比**で、⚠ **曲が 1 曲も無い kind は
    # 分母にも入らない**（→ `TrackLottery#pick_kind`）。
    #
    # 🔴 **分母から外した kind は 0% と出す**（Codex の P2）。⚠⚠ **重みだけで割ると、
    # 1 曲も無い kind が「20% 出る」と表示される** — ⚠ **この画面はまさに
    # 「母集合と設定の食い違い」を見るためのもの**なので、**そこで嘘をつかない。**
    def pool_line(kind, weight, counts, weights)
      count = counts[kind].to_i
      total = weights.select {|name, value| value.positive? && counts[name].to_i.positive?}
        .values.sum
      share = count.positive? && total.positive? ? (weight * 100.0 / total) : 0.0
      marker = song.collection_kinds.include?(kind) ? ' ⚠ アルバム名を出す' : ''
      # ⚠ **重みが付いているのに 1 曲も無い**のは設定漏れの合図（→ `TrackLottery#warn_unweighted`
      # の裏返し）。🔴 **0% とだけ書くと「重みが 0 なのか曲が無いのか」が読めない。**
      marker = "#{marker} 🔴 曲が 1 曲も無い" if count.zero? && weight.positive?
      return "  #{kind.to_s.ljust(13)} 重み #{weight}  #{count} 曲  #{share.round(1)}%#{marker}"
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
    def dump_samples(names, count)
      names.each do |kind|
        puts "=== #{kind} ==="
        song.lottery.candidates.where(kind: kind).order(Sequel.lit('RANDOM()'))
          .limit(count).each do |track|
          prefix = song.source.prefix(first_slot, kind: song.source.spoken?(track) ? nil : kind)
          puts song.source.presenter(track, prefix).to_s.each_line.map {|line| "  #{line}"}.join
          puts
        end
      end
      return nil
    end

    # 🔴 **黙る日はそう書く**（Codex の P1）。⚠⚠ **枠だけを並べると、下見と実機が
    # 食い違う** — ⚠ **11/3 / 11/4 はライブが持っているので 1 通も出ない。**
    def dump(date, days)
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
