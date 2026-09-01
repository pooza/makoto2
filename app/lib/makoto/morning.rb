module Makoto
  # 朝挨拶（#17）。**絞り込んだ 4 機能のひとつ**で、**日常の活動の 1 本目。**
  #
  # ⚠⚠ **「朝の冠番組に出演していて、その最初の挨拶をしている」というテイ。**
  # 定型挨拶 ＋ 他愛もない日常話という構造は**宮本さんの「キッズ劇場」由来**
  # （→ [makoto-persona.md](../../../docs/makoto-persona.md)）。
  #
  # | 枠 | 時刻 | 中身 |
  # | --- | --- | --- |
  # | `morning` | 07:00 | 定型挨拶 ＋ `morning` から 1 本（→ `MorningSource`） |
  #
  # ⚠ **枠は 1 日 1 本。**⚠⚠ **日付が特定された日は原稿が上書きする**（#12 の段 1 / 2）
  # ので、**枠の側は日付を知らない**（→ `Announcement` と同じ形）。
  #
  # 🔴 **07:00 は旧アカウントの実測。**⚠ **予告の 10:00 とも、日曜の実況の窓
  # （08:30〜09:00）とも重ならない**（→ `CommentaryWindow`）。
  class Morning
    include Package

    PREFIX = '/morning'.freeze

    # ⚠ **冪等キーの前半になるので動かさない**（`morning-{枠の時刻 UTC}`）。
    # 原稿の type を変えてもキーが動かないよう、type とは別に持つ。
    NAME = 'morning'.freeze

    # @param repository [MessageRepository] テストが差し替えるためだけの口
    def initialize(repository: nil)
      @repository = repository
    end

    # 日替わりで回す原稿の type。⚠ **定型挨拶が付くのはこちらだけ。**
    def type
      return config["#{PREFIX}/type"].to_s
    end

    # 日付が特定された日に上書きする原稿の type。⚠⚠ **挨拶は原稿が自分で持つ。**
    def dated_types
      return Array(optional_config("#{PREFIX}/dated_types", [])).map(&:to_s)
    end

    # 使ってよい原稿の type。⚠ **許可リストに無い type は日付が一致しても選ばれない**
    # （ライブの台本を朝挨拶が横取りしない → `MessageSelector`）。
    def types
      return [type, *dated_types].uniq
    end

    # 定型挨拶。⚠ **空にすれば付かない。**⚠⚠ **変えるのにコード変更は要らない。**
    def greeting
      return optional_config("#{PREFIX}/greeting").to_s
    end

    def timetable
      @timetable ||= Timetable.new(
        start: config["#{PREFIX}/timetable/start"],
        finish: config["#{PREFIX}/timetable/finish"],
        interval: config["#{PREFIX}/timetable/interval"],
      )
      return @timetable
    end

    def selector
      @selector ||= MessageSelector.new(types, repository: @repository)
      return @selector
    end

    def source
      @source ||= MorningSource.new(
        selector: selector, greeting: greeting, greeted_types: [type],
      )
      return @source
    end

    def job
      validate
      return PostingJob.new(name: NAME, timetable: timetable, source: source)
    end

    private

    def validate
      validate_type
      validate_window
      return nil
    end

    # 🔴 **日替わりの type を記念日に登録させない。**⚠⚠ **記念日に予約された type は
    # 段 4 / 5（季節・無指定）から外れる**ので（→ `MessageSelector#rotating_types`）、
    # ⚠ **`morning` を登録した瞬間に、その日以外は 1 本も引けなくなる。**
    #
    # ⚠⚠ **`Announcement#validate` とは向きが逆**（あちらは「登録が無いと毎日出る」、
    # こちらは「登録が有ると毎日出ない」）。🔴 **どちらも表面化するのは翌朝以降**なので、
    # **設定の側で止める。**
    def validate_type
      return unless selector.reserved_types.include?(type)
      raise Ginseng::ConfigError,
        "morning: type '#{type}' must not be registered in /message/anniversary"
    end

    # 🔴 **日曜 08:30〜09:00 の実況の窓に枠を置かない**（#172）。⚠⚠ **人が話している
    # ところへ定型文を差し込むのは上書き**（→ `CommentaryWindow`）。
    def validate_window
      window = CommentaryWindow.new
      return unless window.conflict?(timetable)
      raise Ginseng::ConfigError,
        "morning: timetable (#{timetable}) must avoid the commentary window (#{window})"
    end
  end
end
