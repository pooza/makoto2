module Makoto
  # 出した曲の履歴を読み書きする口（#41）。
  #
  # ⚠ **判断はここに置かない**（何本避けるか・避けきれないときどうするかは
  # `TrackHistory`）。🔴 **ここは行の出し入れだけ。**
  class TrackHistoryRepository
    def initialize(db = Database.connection)
      @db = db
    end

    def dataset
      return @db[:track_history]
    end

    def by_post(post, records = dataset)
      return records.where(post: post.to_s)
    end

    # 直近 `size` 件の `dedupe_key`。
    #
    # ⚠⚠ **並びは `id`（採番順）で見る** — ⚠ **`posted_at` は同じ秒に 2 行入ると
    # 順序が決まらない**（枠は 7 時間離れているので実際には起きないが、
    # **順序の根拠を時刻に置くと、時刻を騙すテストやリハーサルで崩れる**）。
    def recent_keys(post, size)
      return [] unless size.to_i.positive?
      return by_post(post).reverse(:id).limit(size.to_i).select_map(:dedupe_key)
    end

    def record(post, dedupe_key, posted_at = Time.now)
      return dataset.insert(
        post: post.to_s,
        dedupe_key: dedupe_key.to_s,
        posted_at: posted_at,
      )
    end

    def count(post = nil)
      return dataset.count unless post
      return by_post(post).count
    end

    # ⚠ **いちばん新しい 1 行**（下見が「最後に出したのはいつか」を出すのに使う）。
    def last(post)
      return by_post(post).reverse(:id).first
    end
  end
end
