module Makoto
  # 🔴 **表に書いたのに 1 行も当たらないもの**を残す（`TrackImporter` の取り込みの後）。
  #
  # ⚠ **切り出したのは `Metrics/ClassLength` に当たったから**（v0.9.0 のリリース前レビューの黄で
  # 歌手の一覧を先に引く行を足した）。🔴 **境目は「取り込んだ後に表と突き合わせて警告する」**で、
  # 取り込みそのもの（行を当てる・正す）は `TrackImporter` に残してある。
  #
  # ⚠ 使う側が `@db` / `aliases` / `daily_ids` / `logger` を持っていること。
  module TrackUnusedReport
    private

    # 🔴 **1 行も当たらない表記を残す**（#123）。⚠⚠ **訂正表の `fixed` と同じ合図**で、
    # **供給元が表記を揃えたか、そもそも書き間違えている** — ⚠ **どちらでもその行は
    # 消せる。**🔴 **黙ると、効いていない行がいつまでも表に残る。**
    def report_unused_aliases
      return nil if aliases.empty?
      present = @db[:track].select_map(:name).to_set {|name| self.class.normalize(name)}
      unused = aliases.keys.reject {|key| present.include?(key)}
      return nil if unused.empty?
      logger.warn(track: 'alias', state: 'unused', key: unused)
      return unused
    end

    # 🔴 **名前で書く表で、1 行も当たらない名前を残す**（語りの表 #298 → `SpokenTracks`・MV の表 #498 →
    # `MusicVideos`）。⚠⚠ **配信が終わったか、書き間違えている** — ⚠ **黙ると、表に書いたのに効いていない
    # ことに気づけない**（**語りの表なら歌向けの前置きが付いたまま、MV の表なら音源のリンクのまま**で、
    # **投稿を見ても分からない**）。
    def report_unused_names(label, table)
      return nil if table.empty?
      unused = table.unused(@db[:track].select_map(:dedupe_key).to_set)
      return nil if unused.empty?
      logger.warn(track: label.to_s, state: 'unused', name: unused)
      return unused
    end

    # 🔴 **訂正表と分類の表で、普段用の曲データに無い `id` を残す**（#317）。⚠⚠ **黙って無視していた**
    # ので、**配信が終わった曲や書き間違えた `id` の行は「表に書いたのに効いていない」まま残った**
    # （別名表・語りの表の `unused` と同じ合図）。
    def report_unused_entries(label, entries)
      unused = entries.keys - daily_ids.to_a
      return nil if unused.empty?
      logger.warn(track: label.to_s, state: 'unused', id: unused)
      return unused
    end
  end
end
