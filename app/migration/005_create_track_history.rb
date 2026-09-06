Sequel.migration do
  # 出した曲の履歴（#41）。⚠ **次の抽選で最近出したものを避けるためだけに持つ。**
  #
  # 🔴 **進行位置ではない**（→ docs/CLAUDE.md「投稿の欠落は詰めない。進行位置は
  # 状態ではなく計算で出す」）。⚠⚠ **「いま何番目の投稿か」をここから復元しない** —
  # **`Timetable` が状態を持たない利点が消える。**
  #
  # ⚠⚠ **鍵は `track.id` ではなく `dedupe_key`。**⚠ **同じ曲が名義違い・盤違いで
  # 複数行ある**（ライブ用 vocal は 194 行で曲名ユニーク 134）ので、🔴 **id で記録
  # すると同じ曲が別名義で何度も出る**（→ docs/track-corpus.md）。
  #
  # ⚠ **`track` への外部キーは張らない。**🔴 **鍵は曲であって行ではない**ので、
  # ⚠⚠ **曲データを入れ直して id が変わっても履歴は生き残る**（`makoto track import`
  # は何度でも流せる）。
  #
  # ⚠ **`post` は枠の名前**（いまは `song` だけ）。🔴 **枠ごとに別の履歴として読む** —
  # ⚠⚠ **後から別の枠が曲を出すようになったとき、黙って履歴を共有しない。**
  #
  # ⚠ **行は増える一方だが 1 日 2 本**なので、10 年で 7,300 行。**掃除の当番は作らない。**
  change do
    create_table(:track_history) do
      primary_key :id
      String :post, null: false
      String :dedupe_key, null: false
      DateTime :posted_at, null: false
      # ⚠ **直近を引くための索引。**🔴 **並びは `posted_at` ではなく `id`**（採番順）
      # — ⚠⚠ **同じ秒に 2 行入ると `posted_at` では順序が決まらない。**
      index [:post, :id]
    end
  end
end
