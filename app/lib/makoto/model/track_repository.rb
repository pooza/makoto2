module Makoto
  # 曲を引く口。
  #
  # ⚠ **`live` はライブ用（#13）、それ以外を含む全体は普段の曲紹介用（#16）。**
  # ライブ用は普段用の部分集合なので、表は 1 つで足りる。
  #
  # ⚠⚠ **「何曲あるか」を行数で答えない。**同じ曲が名義違い・盤違いで複数行あり、
  # ライブ用 vocal は 194 行に対して曲名ユニークが 134 しかない。8 時間の枠が
  # 埋まるかどうかは行数ではなく `dedupe_key` の数で見る（→ #13）。
  class TrackRepository
    def initialize(db = Database.connection)
      @db = db
    end

    def dataset
      return @db[:track]
    end

    # ライブ用（#13）。
    def live(records = dataset)
      return records.where(live: true)
    end

    def by_kind(kind, records = dataset)
      return records.where(kind: kind.to_s)
    end

    # 紹介できる曲だけ。⚠ **曲紹介はリンク付きで曲そのものを出す**ので、
    # `url` が無い行は紹介の形にならない（→ docs/track-corpus.md）。
    def linkable(records = dataset)
      return records.exclude(url: nil)
    end

    # 重複を寄せた 1 曲につき 1 行。⚠ **同じ曲を 2 度出さないための入口はここ。**
    # どの行を代表にするかは `id` の小さいほうで安定させる。
    def distinct(records = dataset)
      representatives = records.group(:dedupe_key).select {min(:id)}
      return dataset.where(id: representatives)
    end

    def count
      return dataset.count
    end

    # ⚠ 行数ではなく曲数。枠が埋まるかの判断はこちらを見る。
    # ⚠ `count(:dedupe_key)` では非 null の行数になってしまうので、列を絞って
    # から `distinct` を掛ける。
    def dedupe_key_count(records = dataset)
      return records.select(:dedupe_key).distinct.count
    end

    # kind => 件数。`makoto track stat` と、抽選の重み付け（#11）が使う。
    def count_by_kind(records = dataset)
      return records.group_and_count(:kind).to_hash(:kind, :count)
    end
  end
end
