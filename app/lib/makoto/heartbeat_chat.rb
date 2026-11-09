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

    # 🔴 **認証以外の失敗が続いていること**（#611）。⚠⚠ 残高切れの 400・モデル名の誤りの 404・タイムアウトは、
    # 1 通ごとに Sentry へ出るだけで、`makoto status` には出なかった。⚠ 1 回通れば消える。
    def record_chat_failure(now: nil)
      return update do |record|
        record.merge(
          chat_failures: record[:chat_failures].to_i + 1,
          chat_failed_since: record[:chat_failed_since] || (now || Time.now).getutc.iso8601,
        )
      end
    end

    def chat_failures
      return stored[:chat_failures].to_i
    end

    def chat_failed_since
      return parse_time(stored[:chat_failed_since])
    end

    # ⚠ **書いてあるときだけ書き直す**（返事のたびに鍵を取りに行かない）。
    def clear_chat_failures
      keys = [:chat_auth_failed_at, :chat_failures, :chat_failed_since]
      return nil unless keys.any? {|key| stored.key?(key)}
      return update {|record| record.except(*keys)}
    end

    # 🔴 **フォロワーの一覧が一度も引けていないこと**（#611）。⚠⚠ その間、門は全員に黙る（`followers_unknown`）。
    # ⚠ 引けたら消える。⚠ 前の一覧があるときの失敗は書かない（前の一覧で答えられる）。
    def record_followers_unloaded(now: nil)
      return update do |record|
        record.merge(followers_unloaded_since: record[:followers_unloaded_since] ||
          (now || Time.now).getutc.iso8601)
      end
    end

    def clear_followers_unloaded
      return nil unless stored.key?(:followers_unloaded_since)
      return update {|record| record.except(:followers_unloaded_since)}
    end

    def followers_unloaded_since
      return parse_time(stored[:followers_unloaded_since])
    end

    # 死んでいる別スレッドの名前（#611）。⚠ tick ごとに書き直す（→ `Scheduler#record_tick`）。
    def dead_threads
      return Array(stored[:dead_threads]).map(&:to_s)
    end
  end
end
