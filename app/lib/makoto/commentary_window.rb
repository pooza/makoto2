module Makoto
  # 🔴 **日曜 08:30〜09:00 はキュアスタ！の「実況の時間」**（#172）。⚠⚠ **MAKOTO は
  # 割り込まない** — **増幅であって制度化ではない**（→ [CLAUDE.md](../../../docs/CLAUDE.md)
  # 「コミュニティ・文化に資する」）。
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

    # ⚠ **曜日。0 が日曜**（`Time#wday` と同じ）。
    #
    # 🔴 **範囲の外なら落とす**（Codex の P2）。⚠⚠ **`7` のような値だと `cover?` が
    # 何にも当たらなくなり、検査そのものが黙って無効になる。**⚠ **schema は誤りを
    # 報告するが、`MakotoDaemon#validate_config` は記録して起動を続ける**（#99）ので、
    # **ここで落とさないと fail-open になる。**
    def weekday
      value = config["#{PREFIX}/weekday"].to_i
      return value if value.between?(0, 6)
      raise Ginseng::ConfigError,
        "commentary: weekday must be 0..6 (got '#{config["#{PREFIX}/weekday"]}')"
    end

    def timezone
      @timezone ||= TZInfo::Timezone.get(config['/scheduler/timezone'])
      return @timezone
    end

    # その時刻が窓の中か。⚠ **曜日も見る**（平日の 08:30 は窓ではない）。
    def cover?(time = nil)
      time ||= Time.now
      local = timezone.utc_to_local(time.getutc)
      return false unless local.wday == weekday
      minutes = (local.hour * 60) + local.min
      return start_minutes <= minutes && minutes < finish_minutes
    end

    # その枠が窓に落ちるか。⚠⚠ **枠は日付を区別しない**ので、⚠ **該当する曜日を
    # 作って当てる**（→ `Timetable#times`）。
    #
    # 🔴 **見るのは 2 週ぶん**（Codex の P2）。⚠⚠ **夏時間の切り替え日には「存在しない
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
      return '%{weekday} %{start}-%{finish} (%{timezone})' % {
        weekday: Date::DAYNAMES[weekday],
        start: config["#{PREFIX}/start"],
        finish: config["#{PREFIX}/finish"],
        timezone: timezone.identifier,
      }
    end

    private

    # 直近の該当曜日と、その翌週。⚠ **今日がその曜日なら今日**（過去の日付を作らない）。
    def sample_dates
      today = timezone.utc_to_local(Time.now.getutc).to_date
      first = today + ((weekday - today.wday) % 7)
      return [first, first + 7]
    end

    def start_minutes
      @start_minutes ||= parse_clock(config["#{PREFIX}/start"], :start)
      return @start_minutes
    end

    # ⚠ **終わりが始まりより後であること。**⚠⚠ **逆に書かれた窓は「常に外」になり、
    # 検査そのものが黙って効かなくなる**（`00:00` 幅の窓も同じ）。
    def finish_minutes
      return @finish_minutes if @finish_minutes
      minutes = parse_clock(config["#{PREFIX}/finish"], :finish)
      reject_reversed_window if minutes <= start_minutes
      @finish_minutes = minutes
      return @finish_minutes
    end

    def reject_reversed_window
      from = config["#{PREFIX}/start"]
      to = config["#{PREFIX}/finish"]
      raise Ginseng::ConfigError, "commentary: finish (#{to}) must be after start (#{from})"
    end

    # 'HH:MM' を分にする。⚠ **規則は `Timetable#parse_clock` と同じ**（時計の書き方を
    # 設定の中で 2 つにしない）。
    def parse_clock(value, name)
      unless (matches = value.to_s.match(/\A(\d{1,2}):(\d{2})\z/))
        raise Ginseng::ConfigError, "commentary: #{name} must be 'HH:MM' (got '#{value}')"
      end
      minutes = (matches[1].to_i * 60) + matches[2].to_i
      unless matches[1].to_i.between?(0, 23) && matches[2].to_i.between?(0, 59)
        raise Ginseng::ConfigError, "commentary: #{name} is out of range ('#{value}')"
      end
      return minutes % MINUTES_OF_DAY
    end
  end
end
