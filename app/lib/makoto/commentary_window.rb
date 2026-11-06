module Makoto
  # 🔴 **キュアスタ！の「実況の時間」**（#172 / #255）。⚠⚠ **MAKOTO は割り込まない** —
  # **増幅であって制度化ではない**（→ [CLAUDE.md](../../../docs/CLAUDE.md)「コミュニティ・文化に資する」）。
  #
  # 🔴 **実況は 1 つではない。性格はまったく同じで、違うのは強さだけ**（2026-09-05・オーナー）。
  # ⚠⚠ **別の性格なら別の仕掛けを作るが、同じ性格なので同じ仕掛けに強さの軸を足した**（#255）。
  #
  # | 強さ | ふるまい | 窓 |
  # | --- | --- | --- |
  # | `strong` | 🔴 **重なる枠があれば起動を拒否する**（`Scheduler.validate_window`） | ニチアサ |
  # | `weak` | ⚠ **投稿は止めない。起動ログと下見で警告する**（`Scheduler.weak_conflicts`） | 夜実況・振り返り・MX 再放送 |
  #
  # ⚠ **ここが持つのは「自分から出す投稿」の側だけ。**⚠⚠ **呼びかけへの応答を返すか
  # どうかは別の話**で、そちらは #172 が扱う（**出さない ＝ 黙る、ではない**）。
  #
  # ⚠⚠ **枠を決める人が docs を読んでいるとは限らない。**⚠ **`Announcement#validate` と
  # 同じ判断で、設定の側で止める** — 🔴 **重なったことに気づくのは、人が話している
  # ところへ定型文を差し込んだ後**なので、起動時に落とすほうが早い。
  #
  # ⚠ **終わりは含まない（半開区間）。**09:00 ちょうどは窓の外（→ `Timetable`）。
  class CommentaryWindow
    include Package

    PREFIX = '/commentary'.freeze

    # 1 日ぶんの分。⚠ 時計の比較を分に均すためだけに使う。
    MINUTES_OF_DAY = 1440

    STRENGTHS = ['strong', 'weak'].freeze

    # ⚠ **曜日を省いた窓は毎日。**0 が日曜（`Time#wday` と同じ）。
    EVERY_DAY = (0..6).to_a.freeze

    # 設定に書いた窓のすべて。
    #
    # 🔴 **1 つも無ければ落とす。**⚠⚠ **空の配列だと検査がどの枠も通し、黙って無効になる**
    # （schema は `minItems` で報告するが、`MakotoDaemon#validate_config` は記録して起動を続ける・#99）。
    def self.all
      entries = Config.instance["#{PREFIX}/windows"]
      unless entries.is_a?(Array) && entries.present?
        raise Ginseng::ConfigError, 'commentary: windows must be a non-empty list'
      end
      return entries.map {|entry| new(entry)}
    end

    def self.strong
      return all.select(&:strong?)
    end

    def self.weak
      return all.select(&:weak?)
    end

    # 🔴 **弱い窓の検査から外す枠**（2026-11-06・オーナー判断）。⚠⚠ **バースデーライブ当日は
    # 場そのものが違う。**⚠ **強い窓には効かない。**
    def self.weak_exempt?(name)
      return Array(Config.instance["#{PREFIX}/weak_exempt"]).map(&:to_s).include?(name.to_s)
    end

    # 下見（`morning slot` / `song slot`）に出す行。⚠ **弱い窓との重なりはここで見える**
    # （常駐は止めないので、枠を動かす PR の時点で気づく口）。
    def self.summary(job)
      lines = ['実況の窓:'] + all.map {|window| "  #{window}"}
      Scheduler.weak_conflicts(job).each do |window|
        lines.push("  ⚠ 弱い窓と重なる: #{window}（投稿は止めない）")
      end
      return lines
    end

    # @param entry [Hash] 設定の 1 件（`name` / `weekdays` / `start` / `finish` / `strength`）
    def initialize(entry)
      @entry = (entry || {}).to_h.transform_keys(&:to_s)
    end

    def name
      return @entry['name'].to_s
    end

    # 🔴 **知らない強さなら落とす。**⚠⚠ **`strong?` も `weak?` も偽になり、どちらの検査も黙って素通りする。**
    def strength
      value = @entry['strength'].to_s
      return value if STRENGTHS.include?(value)
      raise Ginseng::ConfigError,
        "commentary: #{name}: strength must be #{STRENGTHS.join(' or ')} (got '#{value}')"
    end

    def strong?
      return strength == 'strong'
    end

    def weak?
      return strength == 'weak'
    end

    # ⚠ **曜日。0 が日曜**（`Time#wday` と同じ）。⚠ **省くと毎日**（夜実況）。
    #
    # 🔴 **範囲の外なら落とす**（Codex の P2）。⚠⚠ **`7` のような値だと `cover?` が
    # 何にも当たらなくなり、検査そのものが黙って無効になる。**⚠ **schema は誤りを
    # 報告するが、`MakotoDaemon#validate_config` は記録して起動を続ける**（#99）ので、
    # **ここで落とさないと fail-open になる。**⚠ **空の配列も同じ**（どの日にも当たらない）。
    def weekdays
      return EVERY_DAY unless @entry.key?('weekdays')
      values = Array(@entry['weekdays'])
      if values.empty? || values.any? {|v| !v.is_a?(Integer) || !v.between?(0, 6)}
        raise Ginseng::ConfigError,
          "commentary: #{name}: weekdays must be a list of 0..6 (got '#{@entry['weekdays']}')"
      end
      return values.uniq.sort
    end

    def timezone
      @timezone ||= TZInfo::Timezone.get(config['/scheduler/timezone'])
      return @timezone
    end

    # その時刻が窓の中か。⚠ **曜日も見る**（平日の 08:30 は窓ではない）。
    def cover?(time = nil)
      time ||= Time.now
      local = timezone.utc_to_local(time.getutc)
      return false unless weekdays.include?(local.wday)
      minutes = (local.hour * 60) + local.min
      return start_minutes <= minutes && minutes < finish_minutes
    end

    # その枠が窓に落ちるか。⚠⚠ **枠は日付を区別しない**ので、⚠ **該当する曜日を
    # 作って当てる**（→ `Timetable#times`）。
    #
    # 🔴 **見るのは曜日ごとに 2 週ぶん**（Codex の P2）。⚠⚠ **夏時間の切り替え日には「存在しない
    # 時刻」がある**ので、⚠ **切り替え日だけを見ると、枠の時刻が切り替わりの瞬間へ
    # 寄せられて窓から外れ、検査が黙って素通りする**（`Timetable#instant`）。
    # ⚠ **切り替えが 2 週続くことは無い**ので、2 つ見れば必ず普通の週が入る。
    # ⚠⚠ **`Asia/Tokyo` に夏時間は無いが、タイムゾーンの正本を設定に持つ以上ここで守る**
    # （`Timetable` と同じ判断）。
    def conflict?(timetable)
      return sample_dates.any? do |date|
        timetable.times(date).any? {|time| cover?(time)}
      end
    end

    def to_s
      return '%{name} %{days} %{start}-%{finish} %{strength} (%{timezone})' % {
        name: name,
        days: weekdays == EVERY_DAY ? 'every day' : weekdays.map {|v| Date::DAYNAMES[v]}.join(','),
        start: @entry['start'],
        finish: @entry['finish'],
        strength: strength,
        timezone: timezone.identifier,
      }
    end

    private

    # 該当する曜日ごとに、直近の日と翌週。⚠ **今日がその曜日なら今日**（過去の日付を作らない）。
    def sample_dates
      today = timezone.utc_to_local(Time.now.getutc).to_date
      return weekdays.flat_map do |weekday|
        first = today + ((weekday - today.wday) % 7)
        [first, first + 7]
      end
    end

    def start_minutes
      @start_minutes ||= parse_clock(@entry['start'], :start)
      return @start_minutes
    end

    # ⚠ **終わりが始まりより後であること。**⚠⚠ **逆に書かれた窓は「常に外」になり、
    # 検査そのものが黙って効かなくなる**（`00:00` 幅の窓も同じ）。
    def finish_minutes
      return @finish_minutes if @finish_minutes
      minutes = parse_clock(@entry['finish'], :finish)
      reject_reversed_window if minutes <= start_minutes
      @finish_minutes = minutes
      return @finish_minutes
    end

    def reject_reversed_window
      raise Ginseng::ConfigError,
        "commentary: #{name}: finish (#{@entry['finish']}) must be after start (#{@entry['start']})"
    end

    # 'HH:MM' を分にする。⚠ **規則は `Timetable#parse_clock` と同じ**（時計の書き方を
    # 設定の中で 2 つにしない）。
    def parse_clock(value, key)
      unless (matches = value.to_s.match(/\A(\d{1,2}):(\d{2})\z/))
        raise Ginseng::ConfigError, "commentary: #{name}: #{key} must be 'HH:MM' (got '#{value}')"
      end
      minutes = (matches[1].to_i * 60) + matches[2].to_i
      unless matches[1].to_i.between?(0, 23) && matches[2].to_i.between?(0, 59)
        raise Ginseng::ConfigError, "commentary: #{name}: #{key} is out of range ('#{value}')"
      end
      return minutes % MINUTES_OF_DAY
    end
  end
end
