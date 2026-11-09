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

    # 🔴 **最後に処理し終えたメンションの通知 ID**（#610 → `MentionCatchUp`）。⚠ 大きくなるときだけ書く
    # （追いついた古い通知で戻さない）。⚠ Mastodon の ID は数字の文字列。
    def record_notification_id(id)
      return nil unless id.to_s.match?(/\A\d+\z/)
      return update do |record|
        current = record[:notification_id].to_s
        next record if current.match?(/\A\d+\z/) && current.to_i >= id.to_i
        record.merge(notification_id: id.to_s)
      end
    end

    def notification_id
      return stored[:notification_id]&.to_s
    end

    # 🔴 **処理し終えた（落ちたときも）通知の ID を残す**（→ `ChatResponder#handle_safely`）。
    # ⚠⚠ **追いつけていない間は進めない**（PR #633 の Codex の P2）— 進めると、取りこぼした分が起点より
    # 前になり、二度と引けない。⚠ 書けなくても例外を上げない（処理のスレッドを止めない）。
    def checkpoint_notification(id)
      return nil if stored.key?(:catch_up_pending)
      return record_notification_id(id)
    rescue => e
      logger.error(chat: 'checkpoint', error: e)
      return nil
    end

    # 追いつけなかった（→ `MentionCatchUp`）。⚠ 追いつけるまで起点を止める。
    # ⚠ 止まり始めた時刻を残す（`makoto status` が言う）。
    def hold_notification_id(now: nil)
      return update do |record|
        # ⚠ 時刻として読めない値（前の実装の `true` など）は書き直す（PR #642 の Codex の P2）。
        since = record[:catch_up_pending] if parse_time(record[:catch_up_pending].to_s)
        since ||= (now || Time.now).getutc.iso8601
        record.merge(catch_up_pending: since)
      end
    end

    def catch_up_pending_since
      return parse_time(stored[:catch_up_pending].to_s)
    end

    def release_notification_id
      return nil unless stored.key?(:catch_up_pending)
      return update {|record| record.except(:catch_up_pending)}
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
