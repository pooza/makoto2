Sequel.migration do
  change do
    # 曲。[seed/](../../seed/) の収集物（iTunes Search API・2026-07-29）を移したもの。
    #
    # ⚠ **ライブ用 234 曲は普段用 4,305 曲の部分集合**（実測で確認）。表は 1 つにして
    # `live` フラグで分ける。2 つの表に分けると同じ曲の写しが 2 つになる。
    #
    # ⚠ **`id` は iTunes の `trackId`。**再取得しても同じ id が返るので、投入は
    # 何度実行してもよい（台詞コーパスと同じ方針）。
    create_table(:track) do
      primary_key :id
      Integer :collection_id
      String :name, null: false
      String :artist_name, null: false
      String :collection_name
      Date :release_date
      # 秒ではなくミリ秒。iTunes の `trackTimeMillis` をそのまま持つ。
      Integer :duration
      Integer :track_number
      # 曲紹介はリンク付きで曲そのものを出す（→ docs/track-corpus.md）。
      # ⚠ **`url` が無い曲は紹介の形にならない。**
      String :url
      String :preview_url
      String :artwork_url
      # 収集スクリプトが付けた分類（vocal / bgm / karaoke / tv_size / instrumental）。
      # ⚠ iTunes 由来のフィールドではない。抽選の重み付け（#11）がこれを見る。
      String :kind, null: false
      TrueClass :live, null: false, default: false
      # ⚠ **同じ曲が名義違い・盤違いで複数行ある**（ライブ用 vocal は 194 行で
      # 曲名ユニーク 134）。`id` は行ごとに違うので、id では重複を排除できない。
      #
      # ⚠⚠ **`duration` も使えない。**同一曲でも盤によって 1〜3 秒ばらつく（実測）。
      # 正規化した曲名だけを鍵にする（→ TrackImporter.dedupe_key）。
      String :dedupe_key, null: false
      index :kind
      index :live
      index :dedupe_key
    end
  end
end
