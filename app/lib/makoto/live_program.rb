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
      return optional_config('/live/setlist/cover_prefix')
    end

    # 枠の頭の時刻 → 投稿の本文。⚠ **枠の外・ライブ当日でない・並びの外・原稿が
    # 無ければ nil**（`PostingJob` が「投稿しない」と解釈する）。
    def call(time = nil)
      time ||= Time.now
      list = setlist(time)
      # ⚠ 枠の外・ライブ当日でなければ黙る（**平常日はここで返る**）。
      return nil unless list
      entry = list.at(@timetable.index_at(time))
      return report_silence(time, 'no entry for the slot') unless entry
      text = entry.mc? ? mc_text(entry, time) : track_text(entry)
      return report_silence(time, 'no text for the slot') if text.blank?
      return text
    end

    # 🔴 **ライブ当日に枠が黙ったら警告を残す**（#80 の黄 9）。
    #
    # ⚠⚠ **平常日の空回りと、ライブが壊れて何も出ないのが、ログ上で同じだった。**
    # ⚠ **どちらも `no text` の 1 行**で、⚠⚠ **11/4 に 160 枠が全滅しても、平常日の
    # ログと 1 文字も変わらない** — **人が見ても異常だと気付けない。**
    #
    # ⚠ **ここまで来ているということは、既に「ライブ当日で、枠の中」**（`setlist` が
    # 両方を見てから返している）。⚠⚠ **その状態で本文が無いのは、原稿が無いのでは
    # なく壊れている。**
    #
    # ⚠ **例外にはしない。**⚠⚠ **1 枠の異常で残りの 8 時間を落とさない**
    # （→ docs/CLAUDE.md「投稿の欠落は詰めない」）。
    def report_silence(time, message)
      logger.warn(live: 'program', message: message, at: time.getutc.iso8601)
      return nil
    end

    def track_text(entry)
      return track_presenter(entry).to_s
    end

    # 曲 1 本ぶんの出力。⚠⚠ **下見（`makoto live setlist`）もここを通す**（#62 と同じ理由）
    # — **「ライブでどう見えるか」の正本を 2 つに割らない。**
    #
    # ⚠ **ライブの都合はここが持つ**（→ `TrackPresenter` 冒頭の表）。
    def track_presenter(entry)
      return TrackPresenter.new(
        entry.track,
        prefix: (cover_prefix if entry.cover?),
        # ⚠ 括弧書きを落とすのはライブだけ（#119）。日常の曲紹介（#16）では落とさない。
        plain_name: true,
        artist: show_artist?(entry),
      )
    end

    # 名義を出すか（#121 / #155）。
    #
    # ⚠⚠ **ゲストコーナーは必ず出す** — **他の歌手の持ち歌なので名義が意味を持つ**
    # （→ `CoverSelector`）。🔴 **本編は、自分の名義を含んでいたら隠す。**
    #
    # ⚠ **共演曲も隠す**（2026-08-22・オーナー判断で #121 の「全部自分のときだけ」から
    # 変えた）。⚠⚠ **根拠は劇中設定** — **高橋さんとの曲なども、真琴は「カバーではなく
    # 自分の歌」として歌っている**ので、**共演者の名義はその前提では情報を足さない。**
    # 🔴 **結果、名義が出るのはカバーの数曲だけになる。**
    def show_artist?(entry)
      return true if entry.cover?
      return !own_credit?(entry.track[:artist_name])
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
      scripts = mc_scripts(time)
      return nil if scripts.empty?
      return scripts[script_index(entry, scripts)][:body]
    end

    # 用意されている MC の原稿。⚠ **下見も同じものを見る**（→ `LiveCommand`）。
    def mc_scripts(time = nil)
      return @mc_selector.list(time || Time.now)
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
    # ⚠⚠ **両端だけでは足りない。**⚠ **中間の `後半。` は蝶番（`〜SONGBIRD〜` の再演）の
    # 直後でなければ嘘になる**が、⚠⚠ **台本は「MC の何番目か」、蝶番は「曲の何番目か」で
    # 位置が決まる**ので、**曲数が 1 曲動くだけで入れ替わる**（#73・実際に #58 で起きた）。
    # **蝶番で 2 本の直線に割り、その継ぎ目に名指しの台本を置く。**
    #
    # ⚠ **総数が分からなければ従来どおり巻き戻す**（`Setlist` 以外が作った項目への保険）。
    def script_index(entry, scripts)
      size = scripts.size
      total = entry.mc_total.to_i
      return entry.ordinal % size if total < 1
      return 0 if total < 2 || size < 2
      from, to, script_from, script_to = segment(entry, total, scripts)
      return interpolate(entry.ordinal, from, to, script_from, script_to).clamp(0, size - 1)
    end

    # 用意されている MC の原稿の本数。⚠ **下見が「何本が 2 回出るか」を出すのに使う。**
    def mc_size(time = nil)
      return mc_scripts(time).size
    end

    private

    # 名義に自分が含まれるか（#121 / #155）。
    #
    # ⚠ **一覧は設定に置く**（`/live/setlist/own_artists`）。⚠⚠ **コードに埋めない** —
    # **名義の表記は供給元しだいで増える**（`キュアソード/剣崎真琴(CV:宮本佳那子)`）。
    #
    # 🔴 **括弧の中も見る**（2026-08-23・オーナー判断・#164）。⚠⚠ **`credit_text` を
    # 通さない** — **通すと括弧が落ち、`グロッサムX2(CV:宮本佳那子)` や
    # `キュア・レインボーズ(…宮本佳那子…)` が「自分を含まない名義」として出てしまう。**
    #
    # ⚠ **正規化だけを通す**（`CureApiService.normalize` ＝ NFKC ＋ 空白除去）ので、
    # **`宮本 佳那子` と `宮本佳那子` は寄る。**
    #
    # ⚠⚠ **2026-08-20 の「役名義は名義を出す」（別作品の役名義で、隠すと「誰の曲か」が
    # 消える）は取り下げた。**🔴 **理由は「これはバースデーライブに限った話」だから** —
    # ⚠ **当日は `キュア・レインボーズ` の曲も「本人の持ち歌」というテイで通す**ので、
    # **どの括弧の中に居ても、居るなら隠す。**⚠⚠ **日常の曲紹介（#16）はこの判定を
    # 通らない**（→ `TrackPresenter` 冒頭の表）ので、あちらは名義を出したまま。
    #
    # 🔴 **2026-08-22 に「全部自分」から「含んでいたら」に変えた**（#155）。
    # ⚠⚠ **PR #134 で「含む」から「全部自分」にしたのは、`五條真由美・宮本佳那子` が
    # 1 組のまま来て共演者ごと消えるのを避けるためだった** — ⚠ **その形はいま
    # 「隠してよい」と決まった**（劇中設定 → `show_artist?`）ので、**避ける理由が消えた。**
    #
    # 🔴 **名義を割らない**（#155）。⚠⚠ **区切り位置は「含むか」の答えを変えない** —
    # **自分の名義に区切り文字は入っていない**ので、どこで割っても一致は保たれる。
    # ⚠ **これで中黒の扱い**（`キュア・カルテット` は 1 組・`五條真由美・宮本佳那子` は
    # 2 組、という数で決める曖昧な規則 → `CureApiService.credit_separator`）**を
    # この判定から外せた。**⚠⚠ **割る必要があるのは「何人並んでいるか」を数える側
    # だけ**（#65 の `credit_count`）。
    #
    # 🔴 **本人がメンバーのユニット名義もここに入る**（2026-08-23・**#177**）。
    # ⚠⚠ **`キュア・カルテット` は名義に本人の名前を含まない**ので、
    # **`own_artists` だけでは拾えなかった。**
    #
    # ⚠ **設定が無ければ隠さない**（消せば元の挙動に戻る → #77）。
    # 🔴 **規則そのものは `OwnCredit`** — ⚠⚠ **本編・カバー母集合・表示の 3 箇所が
    # 同じ判定を使う**（食い違うと「本人の曲を借り物として出す」形になる → #177）。
    def own_credit?(value)
      return OwnCredit.own?(value)
    end

    # 台本を割る継ぎ目。⚠ **継ぎ目が 1 つも引けなければ 1 本の直線に戻す**
    # （`Setlist` のアンカーと同じ判断 — 引けなければ黙って別のものを置かない）。
    #
    # ⚠⚠ **継ぎ目は 1 つとは限らない**（#117）。**蝶番（`後半。`）に加えて、
    # ゲストコーナーの宣言が前半・後半に 1 つずつ**あるので、⚠ **最大 4 本の直線**になる。
    def segment(entry, total, scripts)
      points = anchors(entry, total, scripts)
      return [0, total - 1, 0, scripts.size - 1] if points.empty?
      # ⚠ **`entry.ordinal` を含む区間**。手前に継ぎ目が無ければ台本の頭から。
      index = points.rindex {|ordinal, _| ordinal <= entry.ordinal}
      from, script_from = index ? points[index] : [0, 0]
      to, script_to = upto(points[(index || -1) + 1], total, scripts.size)
      return [from, to, script_from, script_to]
    end

    # 区間の終端。⚠⚠ **次の継ぎ目の 1 本手前まで**（#76 の指摘）。
    #
    # ⚠ **継ぎ目そのものを終端にすると、丸めで名指しの台本が継ぎ目の前に出て、
    # 継ぎ目でもう一度出る**（`mc_hinge = 13` / 継ぎ目 5 なら `12 × 5 ÷ 13 = 4.6`
    # が 5 に丸まる）。⚠ 次が無ければ台本の終端。
    def upto(point, total, size)
      return [total - 1, size - 1] unless point
      return [point.first - 1, point.last - 1]
    end

    # 台本を割る継ぎ目 `[MC の番号, 台本の位置]` を前から順に。⚠ **引けないものは捨てる。**
    #
    # ⚠⚠ **両端は継ぎ目ではない**（`0` と終端は区間の側が持つ）ので、**内側だけを見る。**
    def anchors(entry, total, scripts)
      found = [[entry.mc_hinge, hinge_index(scripts)]] + cover_anchors(entry, scripts)
      inside = found.select do |ordinal, index|
        inside?(ordinal, total) && inside?(index, scripts.size)
      end
      return increasing(inside.sort)
    end

    def inside?(value, size)
      return false unless value.is_a?(Integer)
      return value.positive? && value < size
    end

    # ⚠⚠ **前へ進まない継ぎ目は捨てる。**⚠ **残すと台本が巻き戻る**（同じ MC の番号に
    # 2 つ来た日や、台本の並びと塊の並びが食い違った日）。**先に来たほうを残す。**
    def increasing(points)
      return points.each_with_object([]) do |point, kept|
        last = kept.last
        next if last && (point.first <= last.first || point.last <= last.last)
        kept.push(point)
      end
    end

    # ⚠ 蝶番の直後に置く台本（`/live/mc/hinge` の `slug`）。⚠ 無ければ nil。
    def hinge_index(scripts)
      return script_index_of(scripts, optional_config('/live/mc/hinge'))
    end

    # ゲストコーナーの塊の直前に置く台本（`/live/mc/cover` の `slug`）。
    #
    # ⚠⚠ **並び順で塊と対応させる**（1 つ目が前半、2 つ目が後半）。⚠ **塊の数より
    # slug が多ければ余りは引けない**ので、そのぶんは継ぎ目にならない。
    def cover_anchors(entry, scripts)
      ordinals = Array(entry.mc_covers)
      return Array(optional_config('/live/mc/cover')).each_with_index.map do |slug, index|
        [ordinals[index], script_index_of(scripts, slug)]
      end
    end

    def script_index_of(scripts, slug)
      return nil if slug.to_s.empty?
      return scripts.index {|script| script[:slug] == slug.to_s}
    end

    # ⚠ 浮動小数を使わない（同じ日付なら同じ並び、が前提 → `Setlist`）。
    def interpolate(ordinal, from, to, script_from, script_to)
      return script_from if to <= from
      return script_from + Rational((ordinal - from) * (script_to - script_from), to - from).round
    end

    # ⚠ ホストの TZ ではなく `/scheduler/timezone`（→ `Timetable` と同じ正本）。
    def date_of(time)
      return @timetable.timezone.utc_to_local(time.getutc).to_date
    end
  end
end
