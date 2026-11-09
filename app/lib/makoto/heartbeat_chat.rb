module Makoto
  # チャットボット（#18）の痕跡。⚠ **`Heartbeat` の `class << self` から `include` している**ので、
  # `update` / `stored` / `parse_time` はあちらのもの（→ `HeartbeatStream` と同じ形）。
  #
  # 🔴 **LLM の API キーが通らなくなったことを `makoto status` に出す**（2026-11-08・オーナー）。
  # ⚠⚠ **チャットボットは失敗したら黙る**ので、**キーの期限切れは外から何も起きていないように見える。**
  # ⚠ 次に 1 回通れば消える。
  module HeartbeatChat
    def record_chat_auth_failure(now: nil)
      return update do |record|
        record.merge(chat_auth_failed_at: (now || Time.now).getutc.iso8601)
      end
    end

    # ⚠ **書いてあるときだけ書き直す**（返事のたびに鍵を取りに行かない）。
    def clear_chat_auth_failure
      return nil unless stored.key?(:chat_auth_failed_at)
      return update {|record| record.except(:chat_auth_failed_at)}
    end

    def chat_auth_failed_at
      return parse_time(stored[:chat_auth_failed_at])
    end
  end
end
