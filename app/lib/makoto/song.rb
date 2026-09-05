module Makoto
  # 日常の曲紹介（#16）。**絞り込んだ 4 機能のひとつ**で、**日常の活動の 2 本目**
  # （1 本目は朝挨拶 → `Morning`）。
  #
  # ⚠⚠ **目的は「曲名を挙げる」ことではなく「リンク付きで曲そのものを紹介する」**
  # （2026-08-02 決定・#34 → #16）。🔴 **聴ける形で届けるのが目的**なので、
  # ⚠ **配信に無い曲が母集合から漏れるのは欠陥ではなく仕様**
  # （→ [track-corpus.md](../../../docs/track-corpus.md)）。
  #
  # | 枠 | 時刻 | 中身 |
  # | --- | --- | --- |
  # | `song` | 12:00 / 19:00 | 前置き（`song` の原稿）＋ 抽選した 1 曲（→ `SongSource`） |
  #
  # ⚠ **1 日 2 本**（2026-09-04・オーナー判断）。⚠⚠ **朝挨拶と合わせて 3 本/日**で、
  # **旧アカウントの平常時 5〜7 投稿/日 より控えめ** — 🔴 **寡黙な真琴の register に
  # 合わせた**（応答可の平均 12.4 字 → [makoto-persona.md](../../../docs/makoto-persona.md)）。
  #
  # 🔴 **12:00 / 19:00 は、朝挨拶（08:00）・予告（10:00）・ニチアサ実況の窓
  # （日曜 08:30〜09:00）のどれとも重ならない。**⚠⚠ **窓の検査は `Scheduler#register`**
  # （**自分から出す投稿すべてに掛ける** → `CommentaryWindow`）。
  #
  # ## 🔴 2 本目が 19:00 なのは、20:00 が夜実況だから（#254）
  #
  # ⚠⚠ **キュアスタ！の実況は 1 つではない。**⚠ **ニチアサ実況（日曜 08:30〜09:00）と
  # 夜実況（概ね毎晩 20:00〜）があり、🔴 性格はまったく同じで、違うのは強さだけ**
  # （2026-09-05・オーナー）。**どちらも「人が話している場に割り込まない」。**
  #
  # ⚠ **強いほう（ニチアサ）は `CommentaryWindow` が起動を拒否する。**⚠⚠ **弱いほう
  # （夜）はそこまでせず、枠を置かないだけで足りる** — 🔴 **窓にすると 11/4 の
  # `live-close`（20:00 ちょうど）が道連れで起動しなくなる。**
  #
  # ⚠ **窓を複数・強さつきで持つ構造にするかは #255。**
  #
  # ## 🔴 ライブが持つ日は黙る
  #
  # ⚠⚠ **11/3 / 11/4 は枠が正面からぶつかる**（`live-open` が 12:00、`live-eve` が
  # 11/3 の 12:00〜20:00 毎正時なので 19:00 にも当たる）。⚠ **時刻をずらしても解けない** — 🔴 **ライブの進行
  # そのものが 8 時間**なので、**その日に日常の曲を出せば、どの時刻でも割り込む**
  # （→ `SongSource` の「ライブが持つ日は黙る」）。
  #
  # ## ⚠ ハッシュタグは付けない
  #
  # 🔴 **MAKOTO が自分で付けるタグはライブの 1 つだけ**（2026-08-19 決定 →
  # `HashtagSource`）。⚠⚠ **旧アカウントの朝挨拶に 10 年付いていた `#precure_fun` も
  # モロヘイヤのタグ付け**であって、**MAKOTO は出していなかった。**
  # ⚠ **したがってここは `HashtagSource` で包まない**（`Live#tagged` と対称）。
  #
  # ## ⚠⚠ 同じ曲が続けて出ることは、まだ避けられない
  #
  # 🔴 **投稿履歴による重複回避は #41。**⚠ **母数の小さい `kind`（`instrumental` は
  # 32 曲）は 1 曲あたりの露出が `vocal` の約 20 倍**になるので、⚠⚠ **それが入るまでは
  # 重みを低く保つ**（→ track-corpus.md）。
  class Song
    include Package

    PREFIX = '/song'.freeze

    # ⚠ **冪等キーの前半になるので動かさない**（`song-{枠の時刻 UTC}`）。
    # 原稿の type を変えてもキーが動かないよう、type とは別に持つ。
    NAME = 'song'.freeze

    # @param repository [MessageRepository] テストが差し替えるためだけの口
    # @param tracks [TrackRepository] 同上
    # @param random [Random] 同上（抽選の分布を見るテストはシードを固定する）
    def initialize(repository: nil, tracks: nil, random: nil)
      @repository = repository
      @tracks = tracks
      @random = random
    end

    # 前置きに使う原稿の type。
    def type
      return config["#{PREFIX}/type"].to_s
    end

    # 🔴 **アルバム名を主役にする `kind`**（→ `TrackPresenter` の「劇伴は…」）。
    #
    # ⚠ **設定が無ければ出さない**（消せば元の挙動に戻る → #77）。⚠⚠ **`optional_config`
    # で読む** — **素の `config[]` はキーが無ければ例外**なので、**「消せば止まる」と
    # 書きながら消すと常駐が起動しない**形になる（#77）。
    def collection_kinds
      return Array(optional_config("#{PREFIX}/collection_kinds", [])).map(&:to_s)
    end

    # 🔴 **この type が記念日に予約されている日は黙る**（Codex の P1 → `SongSource`）。
    #
    # ⚠ **設定が無ければ黙らない**（消せば元の挙動に戻る → #77）。⚠⚠ **ただし
    # 空にすると 11/3 / 11/4 にライブと正面からぶつかる**ので、**消すのは枠を
    # ライブの外へ動かしたときだけ。**
    def quiet_types
      return Array(optional_config("#{PREFIX}/quiet_types", [])).map(&:to_s)
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
      @selector ||= MessageSelector.new([type], repository: @repository)
      return @selector
    end

    def lottery
      @lottery ||= @random ? TrackLottery.new(@tracks, random: @random) : TrackLottery.new(@tracks)
      return @lottery
    end

    def source
      @source ||= SongSource.new(
        lottery: lottery,
        selector: selector,
        timetable: timetable,
        collection_kinds: collection_kinds,
        quiet_types: quiet_types,
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
      validate_quiet_types
      return nil
    end

    # 🔴 **黙る日の type が実際に予約されていなければ落とす**（Codex の P1）。
    #
    # ⚠⚠ **`/message/anniversary` に無い type を書いても、`quiet?` は永久に false**
    # — ⚠ **検査が黙って無効になり、バースデーライブの開幕に日常の曲が混ざる。**
    # 🔴 **表面化するのは 11/4 の 12:00**（**投稿は取り消せない**）ので、**起動時に落とす。**
    #
    # ⚠ **`Announcement#validate` と同じ判断**（**登録の有無を設定の側で確かめる**）。
    def validate_quiet_types
      missing = quiet_types - selector.reserved_types
      return if missing.empty?
      raise Ginseng::ConfigError,
        "song: quiet type '#{missing.join(', ')}' must be registered in /message/anniversary"
    end

    # 🔴 **前置きの type を記念日に登録させない。**⚠⚠ **記念日に予約された type は
    # 段 4 / 5（季節・無指定）から外れる**ので（→ `MessageSelector#rotating_types`）、
    # ⚠ **`song` を登録した瞬間に、その日以外は前置きを 1 本も引けなくなる。**
    #
    # 🔴 **朝挨拶（#17）より静かに壊れる。**⚠⚠ **あちらは原稿が引けなければ投稿その
    # ものが無くなる**が、⚠ **こちらは曲だけが出続ける** — **投稿は毎日出ているので、
    # 前置きが消えたことに誰も気づけない。**⚠⚠ **だから設定の側で止める。**
    def validate_type
      return unless selector.reserved_types.include?(type)
      raise Ginseng::ConfigError,
        "song: type '#{type}' must not be registered in /message/anniversary"
    end
  end
end
