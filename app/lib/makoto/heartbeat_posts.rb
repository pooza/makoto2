module Makoto
  # 枠ごとの投稿の結末（#86）。🔴 **`Heartbeat` の痕跡の中の `posts` を読み書きする
  # 口だけ**を持つ。
  #
  # ⚠⚠ **判断はここに置かない**（何回で警告するか・いつ古くなるかは `Heartbeat` の
  # `failure_limit` / `failure_stale`）。⚠ **`Heartbeat` の `class << self` から
  # `include` している**ので、`config` / `stored` / `parse_time` はあちらのもの。
  #
  # ⚠ **切り出したのは `Metrics/ClassLength` に当たったから**だが、🔴 **境目は
  # 「痕跡そのもの」と「痕跡の中の枠ごとの結末」**で引いてある。
  module HeartbeatPosts
    # ⚠ **枠の名前が渡らなかったときの入れ物。**⚠⚠ **テストと、名前を持たない
    # 呼び出しが 1 つの束に入る** — 🔴 **`PostingJob` は必ず名前を渡す。**
    UNNAMED_POST = '-'.freeze

    # 最後の成功からの、連続した失敗の数。⚠ **読めなければ 0**（→ `Health`）。
    #
    # 🔴 **全枠の最大**（#86）。⚠⚠ **合計にしない** — **閾値は「1 つの枠が続けて
    # 落ちている」を見るもの**で、**別々の枠が 1 回ずつ落ちたのとは意味が違う。**
    def failures(now: nil)
      live = posts.values.reject {|v| stale_failure?(v, now)}
      return live.map {|v| v[:failures].to_i}.max || 0
    end

    # 枠ごとの結末。⚠ **読めなければ空**（→ `Health`）。
    def posts
      found = stored[:posts]
      return {} unless found.is_a?(Hash)
      return found
    end

    # 🔴 **閾値に達している枠の名前と回数**（#86）。⚠ **`failing?` の根拠を出す口。**
    def failing_posts(limit: nil, now: nil)
      threshold = limit || failure_limit
      return posts.filter_map do |name, value|
        count = value[:failures].to_i
        next nil if count < threshold
        next nil if stale_failure?(value, now)
        [name.to_s, count]
      end.to_h
    end

    # ⚠ **落ちた記録が古すぎるか**（→ `failure_stale`）。
    #
    # ⚠⚠ **時刻が読めない記録は古くない扱い**（🔴 **読めないことを理由に警告を
    # 消すと、いちばん静かに壊れる**）。
    def stale_failure?(value, now = nil)
      seconds = failure_stale
      return false unless seconds
      failed = parse_time(value[:failed_at])
      return false unless failed
      return (now || Time.now) - failed > seconds
    end

    # 🔴 **枠ごとの結末を読む**（#86）。⚠ **無ければ空。**
    def post_record(record, post)
      found = record[:posts]
      return {} unless found.is_a?(Hash)
      return found[post_key(post)] || {}
    end

    # ⚠ **枠ごとの結末を書き換えた痕跡を返す**（元の Hash は触らない）。
    def merge_post(record, post, **values)
      posts = record[:posts].is_a?(Hash) ? record[:posts] : {}
      key = post_key(post)
      return record.merge(posts: posts.merge(key => (posts[key] || {}).merge(values)))
    end

    # ⚠⚠ **痕跡は `symbolize_names: true` で読む**ので、**枠の名前も Symbol に揃える。**
    # 🔴 **揃えないと、書いたものが次の起動で読めない。**
    def post_key(post)
      return post.presence&.to_s&.to_sym || UNNAMED_POST.to_sym
    end
  end
end
