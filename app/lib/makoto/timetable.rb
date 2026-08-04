module Makoto
  # 投稿の枠。開始時刻・終了時刻・間隔から、投稿すべき時刻の列を計算する。
  # ライブ（#13）の 12:00〜20:00 も、日常の定時投稿（#16 / #17）もこれに載る。
  #
  # ⚠ **状態を持たない。**「いま何番目の投稿か」は現在時刻から計算する。旧実装は
  # 孤児プロセスを 11 日分撒いた前科があり（→ [makoto-legacy.md](../../../docs/makoto-legacy.md)）、
  # 常駐が抱える状態は少ないほどよい。**再起動しても計算結果が変わらないので、
  # 進行位置をどこにも保存しなくてよい。**これが #10 の「再起動後の状態復帰」への答え。
  #
  # ⚠ **この設計の帰結として、失敗した投稿は欠落したまま次の枠へ進む**（詰めない）。
  # 旧実装でも同じ判断をした前例がある（→ [CLAUDE.md](../../../docs/CLAUDE.md)）。
  # 詰めるには進行位置を状態として持つことになり、上記の利点が消える。
  #
  # ⚠⚠ **タイムゾーンは必ず明示する。**ライブは 12:00 JST に始まる。稼働先の CT の
  # ローカルタイムが UTC だと 9 時間ずれるが、**ずれても「起動したのに何も起きない」
  # だけ**なので気付きにくい。`/scheduler/timezone` を唯一の正本にする。
  #
  # ⚠ **終了時刻は含まない（半開区間）。**ライブの 20:00 は終了告知のための枠であって
  # 曲の枠ではない（→ [birthday-live.md](../../../docs/birthday-live.md)）。含めると
  # 告知と曲が同じ時刻に重なる。
  class Timetable
    include Package

    attr_reader :timezone, :interval

    def initialize(start:, finish:, interval:, timezone: nil)
      @timezone = create_timezone(timezone)
      @start = parse_clock(start, :start)
      @finish = parse_clock(finish, :finish)
      @interval = parse_interval(interval)
      validate
    end

    # 指定日の投稿時刻の列。⚠ 日付を省略するとタイムゾーン上の「今日」。
    def times(date = nil)
      date ||= today
      from = instant(date, @start)
      to = instant(date, @finish)
      results = []
      # ⚠ 加算は UTC で行う。ローカル時刻に秒を足すと、夏時間の切り替わりを跨いだ
      # ときに 1 時間ずれる。Asia/Tokyo には無いが、正本を設定に持つ以上ここで守る。
      while from < to
        results.push(timezone.utc_to_local(from))
        from += @interval
      end
      return results
    end

    def size(date = nil)
      return times(date).size
    end

    # 枠の中か。⚠ 終了時刻ちょうどは含まない。
    def cover?(time = nil)
      time ||= Time.now
      date = date_of(time)
      return instant(date, @start) <= time && time < instant(date, @finish)
    end

    # 枠の何番目か（0 始まり）。⚠ 枠の外なら nil。
    # **これが「再起動後の状態復帰」そのもの。**落ちて戻ってきても、時刻さえ分かれば
    # 続きの位置が出る。
    def index_at(time = nil)
      time ||= Time.now
      return nil unless cover?(time)
      return ((time - instant(date_of(time), @start)) / @interval).floor
    end

    # その時刻が属する枠の頭。⚠ 枠の外なら nil。
    # ⚠ **`index_at` が「何番目か」、これが「その枠が始まった時刻」。**投稿の側は
    # 後者を冪等キーに使う（→ `PostingJob`）。
    def slot_at(time = nil)
      time ||= Time.now
      index = index_at(time)
      return nil unless index
      return times(date_of(time))[index]
    end

    # 次の投稿時刻。⚠ その日の枠を過ぎていたら翌日の 1 本目を返す。
    def next_after(time = nil)
      time ||= Time.now
      date = date_of(time)
      return times(date).find {|t| time < t} || times(date + 1).first
    end

    def to_s
      return '%{start}-%{finish}/%<interval>ds (%{timezone})' % {start: format_clock(@start),
        finish: format_clock(@finish),
        interval: @interval,
        timezone: timezone.identifier}
    end

    private

    def validate
      # ⚠ Array には `<` が無い（Set の包含として予約されている）。`<=>` で比べる。
      return if (@start <=> @finish).negative?
      from = format_clock(@start)
      to = format_clock(@finish)
      raise Ginseng::ConfigError, "timetable: start (#{from}) must be before finish (#{to})"
    end

    def today
      return date_of(Time.now)
    end

    def date_of(time)
      return timezone.utc_to_local(time.getutc).to_date
    end

    # その日の HH:MM に対応する瞬間（UTC）。
    def instant(date, clock)
      return timezone.local_to_utc(Time.utc(date.year, date.month, date.day, clock[0], clock[1]))
    end

    def create_timezone(name)
      name ||= config['/scheduler/timezone']
      return TZInfo::Timezone.get(name)
    rescue TZInfo::InvalidTimezoneIdentifier => e
      raise Ginseng::ConfigError, "timetable: unknown timezone '#{name}' (#{error_message(e)})"
    end

    # 'HH:MM' を [hour, minute] にする。
    def parse_clock(value, name)
      unless (matches = value.to_s.match(/\A(\d{1,2}):(\d{2})\z/))
        raise Ginseng::ConfigError, "timetable: #{name} must be 'HH:MM' (got '#{value}')"
      end
      hour = matches[1].to_i
      minute = matches[2].to_i
      unless hour.between?(0, 23) && minute.between?(0, 59)
        raise Ginseng::ConfigError, "timetable: #{name} is out of range ('#{value}')"
      end
      return [hour, minute]
    end

    # '2m' のような表記を秒にする。⚠ 0 秒を通すと times が無限ループする。
    def parse_interval(value)
      seconds = Fugit::Duration.parse(value.to_s)&.to_sec
      raise Ginseng::ConfigError, "timetable: bad interval '#{value}'" unless seconds
      unless seconds.positive?
        raise Ginseng::ConfigError,
          "timetable: interval must be positive ('#{value}')"
      end
      return seconds
    end

    def format_clock(clock)
      return '%<hour>02d:%<minute>02d' % {hour: clock[0], minute: clock[1]}
    end
  end
end
