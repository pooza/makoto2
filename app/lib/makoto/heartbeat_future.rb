module Makoto
  # リハーサルが痕跡に残した未来の時刻を捨てる（#421）。🔴 **`Heartbeat.record_start` だけが呼ぶ。**
  #
  # ⚠⚠ **リハーサルは見かけの 11/4 で痕跡を書く**ので、**撤収して実時間で起き直すと
  # `ticked_at` / `started_at` / `failed_at` が未来に残る。**⚠ **`Heartbeat` の `class << self`
  # から `include` している**ので、`parse_time` はあちらのもの（→ `HeartbeatPosts` と同じ形）。
  #
  # ⚠ **切り出したのは `Metrics/ClassLength` に当たったから**だが、🔴 **境目は「痕跡を読み書きする
  # 口」と「起き上がりのときの後始末」**で引いてある。
  module HeartbeatFuture
    # 🔴 **`time` より未来の時刻を痕跡から捨てる**（#421 → `record_start`）。
    #
    # ⚠ **`started_at` / `ticked_at` は消すだけ**（**`record_start` が猶予を張り直す**）。
    # ⚠⚠ **枠の失敗は数ごと 0 に戻す**（→ `forget_future_failures`）— 🔴 **`failed_at` だけを
    # 消すと「時刻が読めない記録は古くない扱い」で、かえって永久に鳴る。**
    #
    # 🔴 **日付を騙している間は `ticked_at` だけ**（→ `forget_future_tick`・`record_start` の注記）。
    def forget_future(record, time)
      return forget_future_tick(record, time) if TimeTravel.active?
      cleaned = record.reject do |key, value|
        [:started_at, :ticked_at].include?(key) && future?(value, time)
      end
      return forget_future_failures(cleaned, time)
    end

    # ⚠ **未来の `ticked_at` だけを捨てる**（日付を騙している間の起き直し → `record_start`）。
    def forget_future_tick(record, time)
      return record.reject {|key, value| key == :ticked_at && future?(value, time)}
    end

    def future?(value, time)
      parsed = parse_time(value)
      return !parsed.nil? && parsed > time
    end

    # 🔴 **未来の `failed_at` を持つ枠の失敗を捨てる**（#421 → `Heartbeat.record_start`）。
    #
    # ⚠⚠ **リハーサルの見かけの時刻で落ちた記録**なので、**実時間の常駐の健全さとは関係が無い。**
    # ⚠ **全枠の `failed_at` は、残った枠のうちいちばん新しいものに引き直す**（**無ければ消す**）。
    def forget_future_failures(record, time)
      posts = record[:posts].is_a?(Hash) ? record[:posts] : {}
      kept = posts.to_h do |key, value|
        next [key, value] unless value.is_a?(Hash) && future?(value[:failed_at], time)
        [key, value.except(:failed_at).merge(failures: 0, slots: [])]
      end
      cleaned = posts.empty? ? record : record.merge(posts: kept)
      return cleaned unless future?(cleaned[:failed_at], time)
      latest = kept.values.filter_map {|v| parse_time(v[:failed_at]) if v.is_a?(Hash)}.max
      return cleaned.except(:failed_at) unless latest
      return cleaned.merge(failed_at: latest.getutc.iso8601)
    end
  end
end
