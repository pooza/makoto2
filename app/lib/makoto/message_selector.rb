module Makoto
  # 原稿の上書き機構。**「特定の日は、前もって用意した原稿を使う」**（#12）。
  #
  # ⚠ **`PostingJob` の `source` としてそのまま使える。**`call(時刻)` が本文を返し、
  # **原稿が無ければ nil を返す**（＝通常の生成にフォールバックする合図）。
  #
  # ## 段の順。具体的なものが勝つ
  #
  # | 段 | 引くもの | 旧データでの例 |
  # | --- | --- | --- |
  # | 1 | **その年のその日**（`year` 一致） | 無し（台本 #13 / #14 がここに入る） |
  # | 2 | **毎年のその日**（`year` が NULL） | `holiday` 6 件（元日・プリキュアの日など） |
  # | 3 | **記念日**（`/message/anniversary`） | `birthday` 19 件（11/4） |
  # | 4 | **季節**（`message_season` の月一致） | `morning` 82 件 |
  # | 5 | **無指定**（通年） | `morning` 155 件 |
  #
  # ⚠⚠ **記念日の type は、その日以外では選ばれない。**除かないと、日付を持たない
  # `birthday` 19 件が段 5 に混ざって**毎朝バースデーの原稿が出る**。
  #
  # ⚠ **`type` の許可リストは呼ぶ側が決める。**朝挨拶（#17）は
  # `%w[holiday birthday morning]`、ライブ（#13）は台本の type だけ、という形。
  # ⚠ 許可リストに無い type は、日付が一致しても選ばれない（ライブの台本を朝挨拶が
  # 横取りしない）。
  #
  # ⚠ **`template` 109 件と `calling` 13 件は原稿ではない。**全件が `%s` を含む
  # 穴埋めテンプレート（キーワード学習・呼びかけの名残）で、**そのまま投稿すると
  # `%s` が出る**。許可リストに入れないこと（→ docs/makoto-legacy.md）。
  class MessageSelector
    include Package

    ANNIVERSARY_PREFIX = '/message/anniversary'.freeze

    attr_reader :types, :random

    # @param types [Array<String>] 使ってよい原稿の type
    def initialize(types, repository: nil, random: Random.new)
      @types = Array(types).map(&:to_s)
      raise Ginseng::ConfigError, 'message: no type given' if @types.empty?
      @repository = repository || MessageRepository.new
      @random = random
    end

    # 原稿の本文。⚠ **無ければ nil**（通常の生成に任せる）。
    def call(time = nil)
      message = find(time)
      return nil unless message
      return message[:body]
    end

    # 選ばれた原稿そのもの。⚠ CLI の下見（`makoto message preview`）と、
    # ログに「どの原稿を使ったか」を残すためにある。
    def find(time = nil)
      date = date_of(time || Time.now)
      records = candidates(date)
      return nil unless records
      return pick(records)
    end

    # その日に使う記念日の type。⚠ 設定に無い日なら nil。
    def anniversary_type(date)
      key = '%<month>02d-%<day>02d' % {month: date.month, day: date.day}
      type = anniversary_types[key]
      return nil unless type
      return nil unless @types.include?(type)
      return type
    end

    # 記念日として予約されている type。⚠ **その日以外では選ばれない。**
    def anniversary_types
      @anniversary_types ||= config.keys(ANNIVERSARY_PREFIX).to_h do |key|
        [key.to_s, config["#{ANNIVERSARY_PREFIX}/#{key}"].to_s]
      end
      return @anniversary_types
    end

    private

    # 段の上から順に見て、最初に当たった段を返す。⚠ **同じ段の中は乱択**
    # （優先順位は段でしか付けない）。
    def candidates(date)
      steps(date).each do |step|
        records = step.call
        next unless records
        next unless records.first
        return records
      end
      return nil
    end

    def steps(date)
      return [
        -> {@repository.on_date(date.month, date.day, type: @types, year: date.year)},
        -> {@repository.on_date(date.month, date.day, type: @types)},
        -> {anniversary(date)},
        -> {@repository.in_season(date.month, type: rotating_types)},
        -> {@repository.undated(type: rotating_types)},
      ]
    end

    def anniversary(date)
      type = anniversary_type(date)
      return nil unless type
      return @repository.undated(type: type)
    end

    # 記念日として予約された type を除いた、通年で回してよい type。
    def rotating_types
      types = @types - anniversary_types.values
      return nil if types.empty?
      return types
    end

    def pick(records)
      ids = records.select_map(Sequel[:message][:id])
      return records.first(Sequel[:message][:id] => ids[@random.rand(ids.size)])
    end

    # ⚠ ホストの TZ ではなく `/scheduler/timezone` で日付を出す。ライブは JST の
    # 11/4 に始まる（→ `Timetable`）。
    def date_of(time)
      zone = TZInfo::Timezone.get(config['/scheduler/timezone'])
      return zone.utc_to_local(time.getutc).to_date
    end
  end
end
