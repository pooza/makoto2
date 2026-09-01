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
  # | 3 | **記念日**（`/message/anniversary`） | ⚠ 旧データには無い（#60）。台本の `announcement` / `live_*` |
  # | 4 | **季節**（`message_season` の月一致） | `morning` 82 件 |
  # | 5 | **無指定**（通年） | `morning` 155 件 |
  #
  # ⚠⚠ **記念日の type は、その日以外では選ばれない。**除かないと、日付を持たない
  # 原稿が段 5 に混ざって**毎日出る**（🔴 旧 `birthday` 19 件で実際にそうなる形だった）。
  #
  # ⚠ **`type` の許可リストは呼ぶ側が決める。**朝挨拶（#17）は
  # `%w[holiday morning]`、ライブ（#13）は台本の type だけ、という形。
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
    #
    # ⚠ **予約された日に引けなかったときだけ警告を残す**（→ `report_silence`・#114）。
    def call(time = nil)
      message = find(time)
      return report_silence(time) unless message
      return message[:body]
    end

    # 選ばれた原稿そのもの。⚠ CLI の下見（`makoto message preview`）と、
    # ログに「どの原稿を使ったか」を残すためにある。
    #
    # ⚠ **`Date` をそのまま渡せる。**下見は「その日」を見たいだけなので、時刻を
    # 作らせるとホストの TZ で 1 日ずれる（`Time.parse('2026-11-04 12:00')` は
    # ホストの正午）。⚠ **日付で渡せばタイムゾーンの変換そのものが起きない。**
    def find(time = nil)
      date = date_of(time || Time.now)
      records = candidates(date)
      return nil unless records
      return pick(records)
    end

    # 選ばれた段の原稿を、台本の順に並べたもの。⚠ **無ければ空配列。**
    #
    # ⚠⚠ **`find` が乱択なのに対し、こちらは順序が安定する。**ライブの MC（#13）は
    # 「用意した原稿を台本の順に消化する」ので、枠ごとに引き直すと**同じ原稿が何度も
    # 出て、出ない原稿が残る**。⚠ **順に消化したい呼び出し側はこちらを使う。**
    #
    # ⚠⚠ **並べる鍵は `slug`。id ではない**（#69）。**id は採番の順＝取り込んだ順**なので、
    # ⚠ **あとから台本の途中に 1 本足すと、それが必ず末尾に来る。**台本は位置で意味が
    # 決まるので、⚠ **ファイルの並びがそのまま出る形にする**（`slug` は `ScriptImporter`
    # の upsert の鍵でもあり、原稿の側が持つ唯一の安定した順序）。
    #
    # ⚠ **`slug` を持たない原稿は後ろ**（旧ダンプ 388 件。`list` を使う台本の type には
    # 混ざらないが、混ざっても台本の順序を壊さない位置に落とす）。
    def list(time = nil)
      date = date_of(time || Time.now)
      records = candidates(date)
      return [] unless records
      return records.order(Sequel.asc(:slug, nulls: :last), Sequel[:message][:id]).all
    end

    # 🔴 **通年で回してよい原稿すべて**（**段 4 ＋ 段 5 を 1 つにしたもの**）。⚠ **無ければ空配列。**
    #
    # ⚠⚠ **段の中に 1 件しか無いと、日替わりの順送りが毎日同じ原稿を返す**（#17 の完了条件
    # 「連日で同じ挨拶が続かない」が破れる。Codex の P1）。🔴 **実データの 5 月は季節の
    # 原稿が 1 件しかない**（→ [makoto-legacy.md](../../../docs/makoto-legacy.md)）ので、
    # ⚠ **そのままだと 5 月は 31 日とも同じ挨拶になる。**
    #
    # ⚠ **段の順そのものは変えない**（#12 の「具体的なものが勝つ」）。**広げるかどうかは
    # 呼ぶ側の判断**で、⚠⚠ **日付が特定された原稿（段 1 / 2）と記念日（段 3）は広げない**
    # （→ `MorningSource#candidates`）。
    #
    # ⚠ **並びは `list` と同じ**（`slug` → `id`）。**順送りの位置が安定する。**
    def rotating_list(time = nil)
      date = date_of(time || Time.now)
      types = rotating_types
      return [] if types.empty?
      records = @repository.in_season(date.month, type: types).all
      records += @repository.undated(type: types).all
      return records.sort_by {|record| [record[:slug] ? 0 : 1, record[:slug].to_s, record[:id]]}
    end

    # その日に使える記念日の type。⚠ 許可リストに無いものは外す。設定に無い日なら空。
    def anniversary_types_on(date)
      key = '%<month>02d-%<day>02d' % {month: date.month, day: date.day}
      return anniversary_types.fetch(key, []) & @types
    end

    # 記念日として予約されている type。⚠ **その日以外では選ばれない。**
    #
    # ⚠⚠ **1 日に複数の type を登録できる**（#13）。11/4 は誕生日の原稿とライブの
    # 台本（開始告知・MC・終了告知）が同居し、11/3 は予告と前日増量が同居する。
    # ⚠ **1 日 1 type だと、後から来たほうが記念日に登録できず段 5 に漏れる。**
    def anniversary_types
      @anniversary_types ||= config.keys(ANNIVERSARY_PREFIX).to_h do |key|
        [key.to_s, Array(config["#{ANNIVERSARY_PREFIX}/#{key}"]).map(&:to_s)]
      end
      return @anniversary_types
    end

    # 記念日として予約された type の全体。⚠ 呼び出し側の登録漏れ検査に使う
    # （→ `Announcement#validate` / `Live#validate`）。
    def reserved_types
      return anniversary_types.values.flatten.uniq
    end

    # 🔴 **予約された日に原稿が引けなかったことを警告に残す**（#114）。⚠ **戻り値は常に nil。**
    #
    # ⚠⚠ **「本文が無い」は `PostingJob` では `debug` にしかならない。**⚠ **ライブの 4 枠は
    # 平常日に毎日空回りする設計**なので、あちらを `info` に上げると **11/4 に 160 枠が
    # 全滅した日のログが平常日と 1 文字も変わらない**（→ `PostingJob#exec`）。⚠⚠ **「出る
    # べき日に出なかった」を言えるのは中身を知っている側だけ**なので、ここが言う。
    #
    # ⚠ **予約の無い日は黙る。**⚠⚠ **朝挨拶（#17）・曲紹介（#16）も同じ選択器を使う**ので、
    # 無条件に警告すると **8/15〜10/31 の 2 か月半が延々と黄色になる。**
    #
    # ⚠ **例外にしない。**1 枠の異常で残りを落とさない（→ docs/CLAUDE.md「投稿の欠落は
    # 詰めない」）。
    #
    # ⚠⚠ **`ScriptRotation` は `list` を使うのでここを通らない。**⚠ **あちらから呼ぶために
    # public にしてある**（`live-eve` も 4 枠のうちの 1 つ）。
    def report_silence(time = nil)
      date = date_of(time || Time.now)
      types = anniversary_types_on(date)
      return nil if types.empty?
      logger.warn(message: 'no message for the reserved date', types: types, date: date.to_s)
      return nil
    end

    # 🔴 **日付の規則の正本**（#183 の「同じ規則が 3 箇所で揃っていない」を増やさない）。
    # ⚠ **ホストの TZ ではなく `/scheduler/timezone` で日付を出す。**ライブは JST の
    # 11/4 に始まる（→ `Timetable`）。⚠ `Date` はそのまま（変換すると逆にずれる）。
    #
    # ⚠⚠ **public なのは、原稿を引く側が同じ規則で「その日」を出すため**
    # （→ `MorningSource#index`）。**呼ぶ側に `Date.today` を書かせない。**
    def date_of(value)
      return value if value.is_a?(Date) && !value.is_a?(DateTime)
      zone = TZInfo::Timezone.get(config['/scheduler/timezone'])
      return zone.utc_to_local(value.getutc).to_date
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

    # ⚠⚠ **通年で回してよい type が 1 つも無いときは、段 4 / 5 そのものを飛ばす。**
    # `MessageRepository` は `type: nil` を「絞り込まない」と解釈するので、空の
    # 許可リストを渡すと**他の type の原稿まで引いてしまう**（記念日だけを持つ
    # 呼び出し側が、記念日以外の日に無関係な原稿を出す）。
    def steps(date)
      rotating = rotating_types
      return [
        -> {@repository.on_date(date.month, date.day, type: @types, year: date.year)},
        -> {@repository.on_date(date.month, date.day, type: @types)},
        -> {anniversary(date)},
        -> {rotating.empty? ? nil : @repository.in_season(date.month, type: rotating)},
        -> {rotating.empty? ? nil : @repository.undated(type: rotating)},
      ]
    end

    def anniversary(date)
      types = anniversary_types_on(date)
      return nil if types.empty?
      return @repository.undated(type: types)
    end

    # 記念日として予約された type を除いた、通年で回してよい type。
    def rotating_types
      return @types - reserved_types
    end

    def pick(records)
      ids = records.select_map(Sequel[:message][:id])
      return records.first(Sequel[:message][:id] => ids[@random.rand(ids.size)])
    end
  end
end
