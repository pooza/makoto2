module Makoto
  # ライブ 8 時間の枠に載せる中身（#13）。`PostingJob` の `source` として渡す。
  #
  # ⚠ **枠の番号を `Setlist` に渡して 1 項目を取り、本文にするだけ。**「いま何曲目か」を
  # 覚えないので、⚠ **落ちて戻ってきても曲順がずれない**（→ `Timetable#index_at`）。
  #
  # ⚠⚠ **MC は乱択で引かない。**`MessageSelector#list` で id 順に並べ、**何本目の MC か
  # で決める。**枠ごとに引き直すと、同じ原稿が何度も出て出ない原稿が残る。
  class LiveProgram
    include Package

    # @param gate [MessageSelector] ライブ当日かを判定する口（開始告知の記念日登録）
    def initialize(timetable:, mc_selector:, gate:, repository: nil, cure_api: nil)
      @timetable = timetable
      @mc_selector = mc_selector
      @gate = gate
      @repository = repository
      @cure_api = cure_api
    end

    # カバーに添える断り。⚠ 設定から直に読む（呼び出し側に横流しさせない）。
    def cover_prefix
      return config['/live/setlist/cover_prefix']
    end

    # 枠の頭の時刻 → 投稿の本文。⚠ **枠の外・ライブ当日でない・並びの外・原稿が
    # 無ければ nil**（`PostingJob` が「投稿しない」と解釈する）。
    def call(time = nil)
      time ||= Time.now
      entry = setlist(time)&.at(@timetable.index_at(time))
      return nil unless entry
      return mc_text(entry, time) if entry.mc?
      return TrackPresenter.new(entry.track, prefix: (cover_prefix if entry.cover?)).to_s
    end

    # ⚠⚠ **ライブ当日か。**告知や MC は「その日の原稿が無ければ出ない」で黙るが、
    # ⚠ **曲は原稿ではないので黙らせるものが無い。**これが無いと、毎日 12:02〜20:00 に
    # 8 時間ぶんの曲が流れる。⚠ **日付の正本は `/message/anniversary`**（開始告知の
    # type が登録されている日＝ライブの日）なので、ここでも設定を 2 箇所に割らない。
    def live_day?(time = nil)
      return @gate.anniversary_types_on(date_of(time || Time.now)).any?
    end

    # その日の並び。⚠ **日付ごとに 1 つだけ組んで使い回す**（枠ごとに組み直すと
    # 8 時間で 160 回 DB を舐める）。
    def setlist(time = nil)
      time ||= Time.now
      return nil unless @timetable.cover?(time)
      return nil unless live_day?(time)
      date = date_of(time)
      @setlists ||= {}
      @setlists[date] ||= Setlist.new(
        date: date, slots: @timetable.size(date), repository: @repository, cure_api: @cure_api,
      )
      return @setlists[date]
    end

    # ⚠ **無言の枠を作らない。**用意した本数より MC の枠が多くても何かは出す。
    # ⚠ 1 本も無ければ nil（＝その枠は投稿しない）。
    #
    # ⚠⚠ **下見（`makoto live setlist`）もここを呼ぶ**（#62）。**「何本目の MC が
    # どの原稿になるか」の正本を 2 つに割らない** — 下見で見た並びと実際の投稿が
    # 食い違うと、下見そのものが信用できなくなる。
    def mc_text(entry, time = nil)
      scripts = @mc_selector.list(time || Time.now)
      return nil if scripts.empty?
      return scripts[script_index(entry, scripts.size)][:body]
    end

    # ⚠⚠ **原稿は「進行の何割の位置か」で引く**（#69）。**台本は位置で意味が決まる**
    # （`ここで半分。` / `6時間。` / `最後の1曲。`）ので、⚠ **頭から順に消化して尽きたら
    # 巻き戻す形にすると、`最後の1曲。` が中盤に出て `ここで半分。` が最後に出る。**
    #
    # ⚠ **原稿の本数と枠の数を独立させられる**のが要点。**曲数が動けば MC の枠数も動く**
    # （埋め草は `枠数 − 曲数 − カバー`）ので、⚠⚠ **本数を枠数に合わせて数えるのは
    # 運用に載らない** — 実際、#63 で本編を 8 曲間引いた瞬間に 17 枠が 25 枠になった。
    #
    # ⚠⚠ **両端で合わせる。**⚠ `ordinal × 原稿数 ÷ 枠数` だと、**原稿のほうが多いときに
    # 最後の 1 本が永久に出ない**（25 本 24 枠なら `23 × 25 ÷ 24 = 23` で 24 番目が出ない）。
    # ⚠ **`最後の1曲。` が出ないという、この修正が消そうとした壊れ方そのもの**
    # （#71 のレビュー指摘）。**最初の枠は 1 本目、最後の枠は最後の 1 本**になる式にする。
    #
    # ⚠ **総数が分からなければ従来どおり巻き戻す**（`Setlist` 以外が作った項目への保険）。
    def script_index(entry, size)
      total = entry.mc_total.to_i
      return entry.ordinal % size if total < 1
      return 0 if total < 2 || size < 2
      # ⚠ 浮動小数を使わない（同じ日付なら同じ並び、が前提 → Setlist）。
      return Rational(entry.ordinal * (size - 1), total - 1).round.clamp(0, size - 1)
    end

    # 用意されている MC の原稿の本数。⚠ **下見が「何本が 2 回出るか」を出すのに使う。**
    def mc_size(time = nil)
      return @mc_selector.list(time || Time.now).size
    end

    private

    # ⚠ ホストの TZ ではなく `/scheduler/timezone`（→ `Timetable` と同じ正本）。
    def date_of(time)
      return @timetable.timezone.utc_to_local(time.getutc).to_date
    end
  end
end
