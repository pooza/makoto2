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
  # ⚠ **アンカーの 3 曲だけは曲名で指すしかない**（`/live/setlist/opening` /
  # `closing`）。⚠⚠ **曲名が引けなければ黙って別の曲を置かず、その位置を諦める**
  # （並びは崩さない）。
  class Setlist
    include Package

    PREFIX = '/live/setlist'.freeze

    # 項目 1 つ。⚠ `kind` は `:song`（本編）/ `:cover`（ゲストコーナー）/ `:mc`。
    # ⚠ MC は原稿の側で中身が決まるので、ここでは何本目かだけ持つ。
    Entry = Struct.new(:kind, :track, :ordinal, keyword_init: true) do
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
    def initialize(date:, slots:, repository: nil)
      @date = date
      @slots = slots.to_i
      @repository = repository || TrackRepository.new
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
    def songs
      @songs ||= distinct(@repository.by_kind('vocal', @repository.live))
        .order(:release_date, :id).all
      return @songs
    end

    # ゲストコーナーに置く曲。⚠ **ライブ用に入っていない vocal＝他の歌手の持ち歌。**
    #
    # ⚠⚠ **元ネタ（Song Party♪ vol.8）は各部にゲストコーナーを持つ。**MAKOTO では
    # 「他キャラ・他アカウントの曲に触れる枠」にあたる（→ docs/makoto-persona.md の
    # 「同業者として気にかける」register）。
    #
    # ⚠ **いま引けるのはプリキュアソングだけ。**収集が ①宮本佳那子名義のアルバム
    # ②シリーズ名を種にしたアルバム の 2 系統なので、**プリキュア以外のアニソン・
    # 歌謡曲はそもそもコーパスに無い**（→ #55）。
    def covers
      @covers ||= pick_covers
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

    # アンカー 3 つと、各部に 1 曲ずつは要る。
    def minimum_slots
      return 5
    end

    def cover_size
      return config["#{PREFIX}/cover_size"].to_i
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

    # ⚠⚠ **同じ日付なら毎回同じカバーを引く。**枠ごとに引き直すと再起動で並びが
    # 変わる。⚠ 年で種を変えるので、来年は別の曲になる。
    def pick_covers
      total = cover_size * 2
      return [] unless total.positive?
      # ⚠ `dedupe_key` が NULL の行を部分集合に混ぜない。**`NOT IN` は NULL が 1 つでも
      # 混ざると 1 行も返さない**ので、静かに「カバー無し」になる。
      live_keys = @repository.live.exclude(dedupe_key: nil).select(:dedupe_key)
      pool = distinct(@repository.by_kind('vocal')).exclude(dedupe_key: live_keys).order(:id).all
      return [] if pool.empty?
      return pool.sample(total, random: Random.new(@date.strftime('%Y%m%d').to_i))
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
      return compose(opening, closing, body[0...half], body[half..] || [], fillers)
    end

    # 前半・後半に埋め草（カバーと MC）を割り振って 1 本に繋ぐ。
    def compose(opening, closing, first, second, fillers)
      # ⚠ 枠が足りなければ本編の曲を後ろから落とす。**アンカーは守る。**
      return trim(opening, closing, first, second) if fillers.negative?
      corners = covers.each_slice([cover_size, 1].max).first(2)
      first_extra = fillers / 2
      results = []
      results.push(Entry.new(kind: :song, track: opening)) if opening
      results.concat(half(first, corners[0], first_extra, 0))
      results.push(Entry.new(kind: :song, track: opening)) if opening
      results.concat(half(second, corners[1], fillers - first_extra, first_extra))
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
      items.insert(items.size * 2 / 3, *corner.map {|t| Entry.new(kind: :cover, track: t)})
      return items
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
        next unless placed < count
        next unless ((index + 1) * count / items.size) > placed
        results.push(Entry.new(kind: :mc, ordinal: ordinal_from + placed))
        placed += 1
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
