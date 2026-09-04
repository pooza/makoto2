module Makoto
  # 曲紹介（#16）の下見。⚠ **投稿はしない。**
  #
  # ⚠⚠ **曲は抽選なので、下見は「次に何が出るか」を言い当てられない。**
  # 🔴 **言い当てられるのは前置きだけ**（順送り → `SongSource`）。⚠ **したがってここが
  # 見せるのは 2 つ** — **前置きの並び**と、**`kind` ごとに実際に組んだ本文。**
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
      dump_prefixes
      dump_pool
    rescue Ginseng::ConfigError => e
      warn error_message(e)
      exit 1
    rescue Sequel::DatabaseError => e
      warn "読めませんでした。先に `rake migration:run` を実行してください: #{error_message(e)}"
      exit 1
    end

    private

    # 🔴 **一周の長さ ＝ 前置きの本数 ÷ 1 日の本数**（#223 の規則を通す）。
    # ⚠⚠ **同じ前置きが戻るまでの間隔は、その半分を下回らない。**
    def dump_prefixes
      size = song.selector.list(today).size
      slots = song.timetable.size(today)
      if size.zero?
        puts '前置きの原稿: 0 本（⚠ 曲だけを出します）'
        return nil
      end
      days = size.to_f / slots
      cycle = (days * 10).round / 10.0
      puts "前置きの原稿: #{size} 本（一周 #{cycle} 日・同じ前置きが戻るのは最短 #{cycle / 2} 日）"
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
    def pool_line(kind, weight, counts, weights)
      total = weights.select {|name, value| value.positive? && counts[name].to_i.positive?}
        .values.sum
      share = total.positive? ? (weight * 100.0 / total) : 0
      marker = song.collection_kinds.include?(kind) ? ' ⚠ アルバム名を出す' : ''
      return "  #{kind.to_s.ljust(13)} 重み #{weight}  #{counts[kind].to_i} 曲" \
        "  #{share.round(1)}%#{marker}"
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
    def dump_samples(names, count)
      prefix = song.source.prefix(first_slot)
      names.each do |kind|
        puts "=== #{kind} ==="
        song.lottery.candidates.where(kind: kind).order(Sequel.lit('RANDOM()'))
          .limit(count).each do |track|
          puts song.source.presenter(track, prefix).to_s.each_line.map {|line| "  #{line}"}.join
          puts
        end
      end
      return nil
    end

    def dump(date, days)
      days.times do |offset|
        day = date + offset
        puts "#{day} (#{Date::ABBR_DAYNAMES[day.wday]})"
        song.timetable.times(day).each do |time|
          record = song.source.prefix_record(time)
          label = record ? "[#{record[:id]}] #{record[:type]}" : '前置きはありません'
          puts "  #{time.strftime('%H:%M')} #{label}"
          # ⚠⚠ **曲は抽選なので、下見と実機は一致しない。**⚠ **形を見るためのもの。**
          text = song.source.call(time)
          next puts('    （曲を引けませんでした）') unless text
          text.each_line {|line| puts "    #{line.chomp}"}
        end
      end
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
