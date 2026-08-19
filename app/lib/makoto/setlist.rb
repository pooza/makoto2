module Makoto
  # バースデーライブ 8 時間の並び（#13）。**枠の数だけの項目を、曲・カバー・MC で
  # 埋めたもの。**
  #
  # ⚠⚠ **セットリストは抽選ではなく整列。**日常の曲紹介（#16）が使う `TrackLottery`
  # とは別軸で、**ここでは `kind` の重み付けも一様抽選も使わない**
  # （→ [birthday-live.md](../../../docs/birthday-live.md)）。
  #
  # ⚠ **状態を持たない。**「いま何曲目か」を覚えず、**枠の番号から引く**。落ちて戻って
  # きても並びが変わらない（→ `Timetable#index_at` / docs/CLAUDE.md「投稿の欠落は
  # 詰めない」）。⚠ **同じ日付・同じ枠数なら、何度組んでも同じ並びになること**が
  # この設計の前提。
  #
  # ## 並びの骨格
  #
  # ```
  # [0]        〜SONGBIRD〜            ライブ名そのもの。開始告知の直後
  #            前半（発売日の古い側）    ＋ ゲストコーナー ＋ MC
  # [hinge]    〜SONGBIRD〜（再演）      ⚠ 前後編の蝶番。元ネタが第 2 部の冒頭に置いた
  #            後半（発売日の新しい側）  ＋ ゲストコーナー ＋ MC
  # [last]     こころをこめて            アルバム最終曲。終了告知の直前
  # ```
  #
  # ⚠⚠ **発売日で並べるだけで、キュアソード関連 11 曲が 41〜56%＝中間点をまたぐ位置に
  # 固まる**（実測・2026-08-13）。元ネタの「昼の部の締めから夜の部の前半にかけて集中」
  # が、特別扱いを 1 つも書かずに再現される。**だから蝶番は曲名ではなく位置で決めてよい。**
  #
  # ⚠ **曲名で指すのは 2 曲だけ**（`/live/setlist/opening` / `closing`）。⚠⚠ **ただし
  # 置く位置は 3 つ** — **`opening` は頭と蝶番の 2 回歌う**ため。⚠ **「3 曲」と数えると
  # 設定が 3 つあるように読める**ので、**曲名の数（2）と枠の数（3）を混ぜない。**
  # ⚠⚠ **曲名が引けなければ黙って別の曲を置かず、その位置を諦める**（並びは崩さない）。
  class Setlist
    include Package

    PREFIX = '/live/setlist'.freeze

    # 項目 1 つ。⚠ `kind` は `:song`（本編）/ `:cover`（ゲストコーナー）/ `:mc`。
    # ⚠ MC は原稿の側で中身が決まるので、ここでは位置だけ持つ。
    #
    # ⚠⚠ **`ordinal`（何本目か）だけでなく `mc_total`（全部で何本か）も持つ**（#69）。
    # **台本は位置で意味が決まる**（`最後の1曲。` は最後でなければ嘘になる）ので、
    # ⚠ **`LiveProgram` が「進行の何割か」で原稿を引けるようにする。**
    #
    # ⚠⚠ **`mc_hinge` は蝶番（アンカーの再演）の直後に来る MC の番号**（#73）。
    # ⚠ **台本の中間アンカー（`後半。`）はここに合わせる。**両端（`ordinal 0` と
    # `mc_total - 1`）だけでは、⚠⚠ **中間が曲数の増減で蝶番をまたいでずれる。**
    #
    # ⚠⚠ **`mc_covers` はゲストコーナーの塊の直前に来る MC の番号**（#117・塊ごとに 1 つ）。
    # ⚠ **カバー宣言の台本（`ここから何曲か、お借りした歌を歌う。`）はここに合わせる。**
    # 🔴 **塊の位置と台本の位置は根拠が別**（前者は曲と MC を並べた配列の位置、後者は
    # 「MC の何番目か」）なので、⚠⚠ **繋がないと曲数が動くたびにずれる**（実測で 3 曲）。
    Entry = Struct.new(:kind, :track, :ordinal, :mc_total, :mc_hinge, :mc_covers,
      keyword_init: true) do
      def song?
        return kind == :song
      end

      def cover?
        return kind == :cover
      end

      def mc?
        return kind == :mc
      end

      def to_s
        return "MC ##{ordinal}" if mc?
        label = cover? ? 'カバー' : '曲'
        return "#{label}: #{track[:name]} / #{track[:artist_name]}"
      end
    end

    attr_reader :date, :slots

    # @param date [Date] ライブの日。⚠ **カバーの抽出をこの日で固定する**
    # @param slots [Integer] 枠の数（`Timetable#size`）
    def initialize(date:, slots:, repository: nil, cure_api: nil)
      @date = date
      @slots = slots.to_i
      @repository = repository || TrackRepository.new
      @cure_api = cure_api || CureApiService.new
      # ⚠ カバーは本編と別軸（母集合を絞ってから引く → `CoverSelector`）。
      @cover_selector = CoverSelector.new(date: @date, repository: @repository,
        cure_api: @cure_api)
      validate
    end

    def entries
      @entries ||= build
      return @entries
    end

    # 枠の番号から 1 項目。⚠ **枠の外なら nil**（投稿しない）。
    def at(index)
      return nil unless index
      return nil unless index.between?(0, entries.size - 1)
      return entries[index]
    end

    def size
      return entries.size
    end

    # 本編の曲。⚠ **発売日順。**同じ発売日の中は id で安定させる（実行のたびに
    # 並びが変わると、再起動で曲順がずれる）。
    #
    # ⚠ **バージョン違いはここで 1 曲に寄せる**（#118）。⚠⚠ **`distinct` を通しても
    # 残る**のは、`dedupe_key` が括弧の中身を残すから（→ `TrackName`）。
    def songs
      @songs ||= dedupe_versions(
        distinct(@repository.by_kind('vocal', @repository.live))
          .order(:release_date, :id).all.reject {|track| excluded?(track)},
      )
      return @songs
    end

    # ゲストコーナーに置く曲。⚠ **ライブ用に入っていない vocal＝他の歌手の持ち歌。**
    #
    # ⚠⚠ **元ネタ（Song Party♪ vol.8）は各部にゲストコーナーを持つ。**MAKOTO では
    # 「他キャラ・他アカウントの曲に触れる枠」にあたる（→ docs/makoto-persona.md の
    # 「同業者として気にかける」register）。
    #
    # ⚠⚠ **プリキュア歌手の持ち歌に限る**（cure-api の `/singers`・50 名義）。絞らないと
    # **カラオケレーベル（歌っちゃ王 48 曲）・オルゴール盤・ドラマトラック**が混ざる。
    # ⚠ 曲データの `kind` は当てにならない（歌っちゃ王 125 曲のうち 83 曲が `vocal`
    # に分類されている → #56）ので、**名義の側で落とす。**
    #
    # ⚠ **いま引けるのはプリキュアソングだけ。**収集が ①宮本佳那子名義のアルバム
    # ②シリーズ名を種にしたアルバム の 2 系統なので、**プリキュア以外のアニソン・
    # 歌謡曲はそもそもコーパスに無い**（→ #55）。
    def covers
      @covers ||= @cover_selector.exec
      return @covers
    end

    def to_s
      return "setlist #{@date} #{entries.size} slots"
    end

    private

    def validate
      return if @slots >= minimum_slots
      raise Ginseng::ConfigError,
        "setlist: #{@slots} slots is too few (need #{minimum_slots} or more)"
    end

    # アンカーの枠 3 つ（⚠ **曲名は 2 つ。`opening` を 2 回置く**）と、各部に 1 曲ずつは要る。
    def minimum_slots
      return 5
    end

    # 本編から外す曲（#63）。⚠ アルバム単位と曲単位。
    #
    # ⚠⚠ **`live` フラグを落とす形にしない。**フラグは「本編に出す曲」であると
    # 同時に **「MAKOTO 本人の曲」の印**でもあり、`CoverSelector` が
    # 「`live` に無い vocal ＝ 他の歌手の持ち歌」としてカバー母集合を作っている。
    # ⚠ 落とすと**本編から消えた本人の曲がカバーに流れ込む**（実測で 8 曲）。
    # **並びの都合はここ（ライブの選曲）で持ち、データの区分は触らない。**
    #
    # ⚠ 間引く理由は量ではなく塊 — **発売日順に並べる以上、同じアルバムの曲は必ず
    # 隣接する**ので、そのまま入れると 4 曲続けて流れる（→ docs/CLAUDE.md）。
    def excluded?(track)
      return true if exclusions('collections').include?(dedupe(track[:collection_name]))
      return exclusions('tracks').include?(dedupe(track[:name]))
    end

    # バージョン違いを 1 曲に寄せる（#118）。
    #
    # ⚠⚠ **発売日順に並べる以上、同じ曲の版違いは必ず隣接する**ので、寄せないと
    # 塊で流れる（実測で「ねこ ときどき らいおん」が 6 曲続いた）。⚠ **#63 の間引きと
    # 同じ構造**で、**並びの都合はライブの選曲が持つ** — 🔴 **`live` フラグも
    # `dedupe_key` も触らない。**
    #
    # ⚠ **落とした曲を `CoverSelector` に流さない**（#63 と同じ理由）。ここは
    # `live` の中だけを絞っているので、カバーの母集合（`live` に無い vocal）は動かない。
    #
    # ⚠⚠ **代表を選んでから元の並びで拾い直す。**⚠ **寄せた位置に置くと、代表の
    # 発売日ではない場所に曲が出る**（グループの先頭は但し書き付きの版でありうる）。
    def dedupe_versions(tracks)
      groups = tracks.group_by {|track| version_key(track)}
      ids = groups.values.to_set {|group| representative(group)[:id]}
      return tracks.select {|track| ids.include?(track[:id])}
    end

    # ⚠ **但し書きを落とした曲名を、取り込みと同じ規則で正規化したもの。**
    # ⚠⚠ **`TrackName.base` だけでは寄らない** — `We can!! HUGっと! プリキュア` と
    # `We can HUGっと!プリキュア(Long Intro ver.)` は記号と空白が違う（実データ）。
    def version_key(track)
      return dedupe(TrackName.base(track[:name]))
    end

    # 残す 1 曲。⚠ **但し書きの無いものを優先し、無ければ id の小さいほう。**
    #
    # ⚠⚠ **安定していることが要件**（同じ日付・同じ枠数なら何度組んでも同じ並び）
    # なので、**発売日や url の有無のような動く条件を混ぜない。**
    #
    # ⚠ **アンカーは曲名で引く**（`/live/setlist/opening` / `closing`）ので、
    # ⚠⚠ **但し書きの付いた版を代表にすると、その日のアンカーが黙って消える。**
    # 但し書きの無いものを優先するのは、それを避ける意味もある。
    def representative(group)
      return group.min_by {|track| [plain?(track) ? 0 : 1, track[:id]]}
    end

    def plain?(track)
      return dedupe(track[:name]) == version_key(track)
    end

    def exclusions(name)
      @exclusions ||= {}
      values = Array(optional_config("#{PREFIX}/exclude/#{name}"))
      @exclusions[name] ||= values.map {|value| dedupe(value)}
      return @exclusions[name]
    end

    # ⚠ 曲名の同一視は取り込みと同じ規則を使う（規則を 2 つ持たない）。
    def dedupe(value)
      return TrackImporter.dedupe_key(value)
    end

    def opening_name
      return config["#{PREFIX}/opening"].to_s
    end

    def closing_name
      return config["#{PREFIX}/closing"].to_s
    end

    # ⚠ **代表を選ぶ前に url で絞る。**逆にすると、代表になった行だけ url が無いときに
    # 同じ曲の url がある行ごと落ちる（→ `TrackLottery#candidates` と同じ理由）。
    def distinct(records)
      return @repository.distinct(@repository.linkable(records))
    end

    def find_by_name(name)
      return nil if name.empty?
      return songs.find {|track| track[:name] == name}
    end

    def build
      opening = find_by_name(opening_name)
      closing = find_by_name(closing_name)
      body = songs - [opening, closing].compact
      # ⚠ 蝶番は開始と同じ曲の再演。⚠⚠ 開始が引けなければ再演も置かない
      # （別の曲を勝手に 2 度歌わせない）。
      anchors = [opening, opening, closing].compact
      half = body.size / 2
      fillers = @slots - body.size - anchors.size
      return with_mc_total(compose(opening, closing, body[0...half], body[half..] || [], fillers))
    end

    # ⚠⚠ **MC の総数と蝶番の位置を各 MC に配る**（#69 / #73）。⚠ **組み終わるまで
    # どちらも確定しない**ので最後に 1 回だけ回る。⚠ **これが無いと `LiveProgram` は
    # 「何割の位置か」を出せず、台本が枠数に合わなくなった瞬間に頭から巻き戻る**
    # （`最後の1曲。` が中盤に出た）。
    def with_mc_total(entries)
      total = entries.count(&:mc?)
      hinge = hinge_mc_ordinal(entries)
      covers = cover_mc_ordinals(entries)
      entries.each do |entry|
        next unless entry.mc?
        entry.mc_total = total
        entry.mc_hinge = hinge
        entry.mc_covers = covers
      end
      return entries
    end

    # ゲストコーナーの塊の**直前に来る MC の番号**（#117）。⚠ **塊ごとに 1 つ、前から順。**
    #
    # ⚠⚠ **塊の直前に MC が無ければ `nil`**（前半の埋め草をコーナーが使い切った日など）。
    # 🔴 **詰めない。**⚠⚠ **詰めると後ろの塊が前の塊の宣言と対応してしまう**
    # （`/live/mc/cover` は並び順で塊と対応させる → `LiveProgram#cover_anchors`）。
    # ⚠ **`hinge_mc_ordinal` と同じく、位置は組むときにしか分からない。**
    def cover_mc_ordinals(entries)
      starts = entries.each_index.select {|index| corner_start?(entries, index)}
      return starts.map {|index| entries[0...index].reverse_each.find(&:mc?)&.ordinal}
    end

    # 塊の先頭か。⚠ **2 曲目以降は同じ塊なので数えない。**
    def corner_start?(entries, index)
      return false unless entries[index].cover?
      return false if index.positive? && entries[index - 1].cover?
      return true
    end

    # 蝶番（アンカーの再演）の**直後に来る最初の MC の番号**。⚠ 無ければ nil。
    #
    # ⚠ **位置は組むときに記録する**（`@hinge_index`）。⚠⚠ **あとから曲名で探し直さない** —
    # `opening` が引けなかった日に別の曲を蝶番と取り違える。
    def hinge_mc_ordinal(entries)
      return nil unless @hinge_index
      return entries[@hinge_index..].find(&:mc?)&.ordinal
    end

    # 前半・後半に埋め草（カバーと MC）を割り振って 1 本に繋ぐ。
    def compose(opening, closing, first, second, fillers)
      # ⚠ 枠が足りなければ本編の曲を後ろから落とす。**アンカーは守る。**
      return trim(opening, closing, first, second) if fillers.negative?
      corners = covers.each_slice([@cover_selector.size, 1].max).first(2)
      first_extra = fillers / 2
      # ⚠⚠ **後半の MC は「前半に実際に置いた本数」から続ける。**埋め草の数
      # （`first_extra`）から始めると、⚠ **カバーの本数だけ番号が飛ぶ。**飛ぶと
      # `LiveProgram` の `ordinal % 原稿数` がずれ、**用意した原稿の一部が永久に出ず、
      # 別の一部が 2 回出る**（実測で 8〜11 の 4 本が欠番になっていた）。
      first_corner = (corners[0] || []).first(first_extra)
      results = []
      results.push(Entry.new(kind: :song, track: opening)) if opening
      results.concat(half(first, first_corner, first_extra, 0))
      # ⚠ **蝶番の位置をここで覚える**（#73）。アンカーが引けなければ蝶番も無い。
      @hinge_index = results.size if opening
      results.push(Entry.new(kind: :song, track: opening)) if opening
      results.concat(half(second, corners[1], fillers - first_extra,
        first_extra - first_corner.size))
      results.push(Entry.new(kind: :song, track: closing)) if closing
      return results
    end

    # 片方の部。**曲に MC を織り込んでから、ゲストコーナーを塊のまま差し込む。**
    #
    # ⚠⚠ **順序が効く。**先にコーナーを置くと、**MC がコーナーの内側に落ちて塊が割れる**
    # （実際に 1 本挟まって 4 曲が 3 曲＋1 曲になった）。⚠ 割れると「コーナー」に
    # 見えないので、**MC を先に置いて、コーナーは最後にまとめて入れる。**
    def half(tracks, corner, fillers, ordinal_from)
      corner = (corner || []).first(fillers)
      items = weave(tracks.map {|track| Entry.new(kind: :song, track: track)},
        fillers - corner.size, ordinal_from)
      return items if corner.empty?
      items.insert(corner_position(items), *corner.map {|t| Entry.new(kind: :cover, track: t)})
      return items
    end

    # ゲストコーナーを差し込む位置。⚠ **その部の 2/3。**
    #
    # 🔴 **ただし MC の直後まで手前に寄せる**（#117）。⚠⚠ **宣言の台本（`ここから何曲か、
    # お借りした歌を歌う。`）は「塊の直前の MC」に置く**ので、⚠ **間に曲が挟まると
    # 「ここから」が嘘になる**（実測で 3 曲挟まっていた）。**塊を MC にくっつける。**
    #
    # ⚠ **手前に MC が 1 本も無ければ 2/3 のまま**（前半の頭に寄る日）。
    def corner_position(items)
      target = items.size * 2 / 3
      index = items[0...target].rindex(&:mc?)
      return target unless index
      return index + 1
    end

    # MC を等間隔で挟む。⚠ 端に寄せず、曲の間に散らす。
    def weave(items, count, ordinal_from)
      return items if count < 1
      # ⚠ 曲が 1 本も無い部でも、埋め草の数だけは返す（枠が足りないまま残ると、
      # その枠が黙って無投稿になる）。
      return Array.new(count) {|i| Entry.new(kind: :mc, ordinal: ordinal_from + i)} if items.empty?
      results = []
      placed = 0
      items.each_with_index do |entry, index|
        results.push(entry)
        # ⚠⚠ **1 曲につき 1 本とは限らない。**曲より MC のほうが多い部では
        # 続けて 2 本以上置く必要がある。⚠ ここを `if` 1 回にしていたため、
        # **埋め草が置ききれず枠が余ったまま返っていた**（カバーが 0 件のときに表面化）。
        target = (index + 1) * count / items.size
        while placed < target
          results.push(Entry.new(kind: :mc, ordinal: ordinal_from + placed))
          placed += 1
        end
      end
      return results
    end

    # ⚠⚠ **枠より曲が多いときは、本編を削ってアンカーを残す。**削るのは後ろから
    # （発売日の新しい側）で、⚠ **こころをこめて＝最終曲は必ず残る。**
    def trim(opening, closing, first, second)
      anchors = [opening, opening, closing].compact.size
      room = @slots - anchors
      kept_first = [first.size, room / 2].min
      kept_second = [second.size, room - kept_first].min
      return compose(opening, closing, first.first(kept_first), second.first(kept_second), 0)
    end
  end
end
