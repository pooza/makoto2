module Makoto
  # メンションの受信（#29）の痕跡。⚠ **`Heartbeat` の `class << self` から `include` している**ので、
  # `update` / `stored` / `parse_time` / `started_at` / `config` はあちらのもの（→ `HeartbeatPosts` と同じ形）。
  #
  # ⚠ **切り出したのは `Metrics/ClassLength` に当たったから**だが、🔴 **境目は「受信のスレッドが
  # 書き、`Health` が読む」もの**で引いてある（投稿の枠とは別の系統）。
  module HeartbeatStream
    # 何かが届いた。⚠ **`:thump`（無通信の合図）も含む** — 🔴 **見たいのは「繋がっているか」**で、
    # メンションが来たかではない。
    def record_stream(now: nil)
      return update do |record|
        record.merge(streamed_at: (now || Time.now).getutc.iso8601)
      end
    end

    # 最後に何かが届いた時刻。⚠ **一度も無ければ nil。**
    def streamed_at
      return parse_time(stored[:streamed_at])
    end

    # 受信が止まったとみなすまでの猶予（秒）。⚠ **閾値は設定から出す**（`Heartbeat.limit` と同じ理由）。
    def stream_limit
      seconds = Fugit::Duration.parse(config['/streaming/stale'].to_s)&.to_sec
      unless seconds&.positive?
        raise Ginseng::ConfigError,
          "heartbeat: bad streaming stale '#{config['/streaming/stale']}'"
      end
      return seconds
    end

    # 受信が止まっているか。⚠⚠ **基準は「最後の受信」と「起き上がった時刻」の新しいほう**
    # （→ `Heartbeat.tick_stale?` と同じ）— 🔴 **前の稼働の古い `streamed_at` で、起き上がった直後に鳴らない。**
    def stream_stale?(now = nil)
      last = [streamed_at, started_at].compact.max
      return true unless last
      return ((now || Time.now) - last) > stream_limit
    end
  end
end
