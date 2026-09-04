module Makoto
  # 曲紹介の本文（#16）。**前置き ＋ 抽選した 1 曲**を組む。
  #
  # ```
  # この曲、久しぶりに聴きたくなりました。          ← 前置き（song の原稿・順送り）
  #                                                 ← ⚠ 1 行アキ（TrackPresenter）
  # ♪ Girl's Work                                   ← 曲名
  # 咲(CV:樹元オリエ), 舞(CV:榎本温子), …            ← 名義
  # https://music.apple.com/jp/album/girls-work/…   ← ⚠ プレビューカードはこれに任せる
  # ```
  #
  # ⚠⚠ **曲は抽選、前置きは順送り。**🔴 **同じ投稿の中で 2 つの選び方が同居している**
  # ので、⚠ **下見は前置きしか言い当てられない**（→ `SongCommand`）。
  #
  # ## 🔴 曲は重み付き抽選（#11 → `TrackLottery`）
  #
  # ⚠ **普段用 4,305 行のうち BGM が 53%。**⚠⚠ **一様に引くと曲紹介がサントラだらけに
  # なる**（→ [track-corpus.md](../../../docs/track-corpus.md)）。
  #
  # 🔴 **引けなかったら警告を残す。**⚠⚠ **`PostingJob` は「本文が無い」を `debug` に
  # しか書かない** — ⚠ **ライブの 4 枠は毎日空回りする設計**なのでそれで正しいが、
  # 🔴 **曲紹介は毎日出る枠**なので、**引けないのは異常。**⚠ **黙ると「無人で止まって
  # いる」に気づけない**（→ `MessageSelector#report_silence` と同じ判断）。
  #
  # ## ⚠ 前置きは無くても壊れない
  #
  # 🔴 **原稿が 0 件なら曲だけを出す。**⚠⚠ **前置きは `makoto-scripts` の `song` が
  # 正本**（#224 と同じ形）で、**原稿を書き足すのに実装は動かない。**
  #
  # ⚠ **段の順（#12「具体的なものが勝つ」）はそのまま効く** — 🔴 **ただし
  # `MessageSelector#list` は勝った段だけを返す**ので、⚠⚠ **季節指定の前置きを 1 本
  # 書くと、その月はその 1 本だけが回る**（朝挨拶の「月の中に散らす」は #17 の枠が
  # 1 日 1 本だからできること）。⚠ **前置きは通年で書く。**
  #
  # ## 🔴 前置きは枠ごとに送る（#223 の規則を通す）
  #
  # ⚠⚠ **日付だけで送ると、同じ日の 12:00 と 20:00 が同じ前置きになる。**
  # 🔴 **通し番号は「ユリウス通日 × その日の枠数 ＋ 枠の番号」** — ⚠ **状態を持たない**
  # ので、落ちて戻ってきても・別の箱で下見しても同じ枠には同じ前置きが出る
  # （→ [CLAUDE.md](../../../docs/CLAUDE.md)「進行位置は状態ではなく計算で出す」）。
  #
  # ⚠ **組み替えの規則そのものは [`Rotation`](rotation.rb)**（朝挨拶と共通・#183）。
  class SongSource
    include Package

    # @param lottery [TrackLottery] 曲を引く口
    # @param selector [MessageSelector] 前置きを引く口
    # @param timetable [Timetable] 枠。⚠ **通し番号を出すのに要る**
    # @param collection_kinds [Array<String>] アルバム名を出す kind（→ `TrackPresenter`）
    def initialize(lottery:, selector:, timetable:, collection_kinds: nil)
      @lottery = lottery
      @selector = selector
      @timetable = timetable
      @collection_kinds = Array(collection_kinds).map(&:to_s)
    end

    # ⚠ **枠の外・曲が引けなければ nil**（＝その枠は投稿しない）。
    def call(time = nil)
      time ||= Time.now
      return nil unless @timetable.index_at(time)
      track = draw
      return nil unless track
      return presenter(track, prefix(time)).to_s
    end

    # その枠の前置き。⚠ **原稿が 1 件も無ければ nil**（＝曲だけを出す）。
    # ⚠⚠ **`Date` をそのまま渡せない** — **枠の番号は時刻からしか出ない。**
    def prefix(time = nil)
      time ||= Time.now
      index = @timetable.index_at(time)
      return nil unless index
      record = prefix_record(time, index)
      return nil unless record
      return record[:body]
    end

    # その枠の前置きの原稿そのもの。⚠ **下見とログのためにある**（→ `SongCommand`）。
    def prefix_record(time = nil, index = nil)
      time ||= Time.now
      index ||= @timetable.index_at(time)
      return nil unless index
      records = @selector.list(time)
      return nil if records.empty?
      return Rotation.pick(records, serial(time, index))
    end

    # 曲 1 本ぶんの出力。⚠ **下見もここを通す**（#159 と同じ理由 — **「どう見えるか」の
    # 正本を 2 つに割らない**）。
    def presenter(track, prefix = nil)
      return TrackPresenter.new(
        track,
        prefix: prefix,
        # ⚠ **括弧書きは落とさない**（#119）。🔴 **`(TVサイズ)` `(オリジナル・カラオケ)`
        # は、その行が何なのかを言っている唯一の手掛かり。**⚠⚠ **ライブは落とす**
        # （→ `TrackPresenter` 冒頭の表）。
        plain_name: false,
        # ⚠ **名義は出す**（#121）。⚠⚠ **ライブは自分名義を隠す**が、**日常はどの
        # 歌手の曲かが情報**（→ 同上）。
        artist: true,
        collection: collection?(track),
      )
    end

    private

    # 🔴 **その枠の通し番号。**⚠⚠ **日付だけだと同じ日の 2 本が同じ前置きになる。**
    #
    # ⚠ **日付の規則は `MessageSelector` が正本**（`/scheduler/timezone` で出す）。
    # ⚠⚠ **ここで `Date.today` を使わない** — **UTC のホストでは日付が 1 日ずれる。**
    def serial(time, index)
      date = @selector.date_of(time)
      return (date.jd * @timetable.size(date)) + index
    end

    # ⚠ **アルバム名を主役にする kind か**（→ `TrackPresenter` の「劇伴は…」）。
    def collection?(track)
      return @collection_kinds.include?(track[:kind].to_s)
    end

    # 🔴 **引けなかったら黙らない。**⚠⚠ **母集合が空・重みが全部 0 は設定の誤り**で、
    # ⚠ **曲紹介が無言で止まる**（→ `TrackLottery`）。
    #
    # ⚠ **例外は上げない。**1 枠の異常で常駐を落とさない（→ docs/CLAUDE.md
    # 「投稿の欠落は詰めない」）。⚠⚠ **設定の誤りは `TrackLottery` が例外にする**ので、
    # **ここが受けるのは「母集合が空」だけ。**
    def draw
      track = @lottery.draw
      return track if track
      logger.warn(post: Song::NAME, message: 'no track to introduce')
      return nil
    end
  end
end
