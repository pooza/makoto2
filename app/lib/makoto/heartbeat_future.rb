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
    # ⚠ **枠の成功（`posted_at`）も捨てる**（#441 → `forget_future_successes`）。
    #
    # 🔴 **日付を騙している間は `started_at` / `ticked_at` だけ**（#421 の Codex の P1 ×2・#442）—
    # ⚠⚠ **失敗と成功は同じリハーサルの証拠なので残す**（→ `record_start` の注記）。
    def forget_future(record, time)
      cleaned = record.reject do |key, value|
        [:started_at, :ticked_at].include?(key) && future?(value, time)
      end
      return cleaned if TimeTravel.active?
      return forget_future_successes(forget_future_failures(cleaned, time), time)
    end

    def future?(value, time)
      parsed = parse_time(value)
      return !parsed.nil? && parsed > time
    end

    # 🔴 **未来の `failed_at` を持つ枠の失敗を捨てる**（#421 → `Heartbeat.record_start`）。
    #
    # ⚠⚠ **リハーサルの見かけの時刻で落ちた記録**なので、**実時間の常駐の健全さとは関係が無い。**
    # ⚠ **全枠の `failed_at` は、残った枠のうちいちばん新しいものに引き直す**（**無ければ消す**）。
    #
    # 🔴 **割り切り: その枠がリハーサルの前から実時間で落ち続けていた本数も一緒に消える**（#446）。
    # ⚠⚠ **`failures` は本数しか持たず、どの失敗が見かけの時刻のものかを分けられない。**⚠ **残すと
    # 撤収後も赤が最長 6 週間居座る**（#421）ので、**消すほうを選んだ。**⚠ **本当に落ち続けている枠なら
    # 次の実時間の失敗で数え直される。**影響は日付を騙す `bydo` だけ（`rubicon` は騙さない）。
    def forget_future_failures(record, time)
      return forget_future_posts(record, time, :failed_at) do |value|
        value.except(:failed_at).merge(failures: 0, slots: [])
      end
    end

    # ⚠ **未来の `posted_at` を捨てる**（#441）。⚠⚠ **残すと `makoto status` の "last success" と
    # `/healthz/posting` の文面が見かけの 11/4 を言い続ける**（判定には使わないので表示だけ）。
    def forget_future_successes(record, time)
      return forget_future_posts(record, time, :posted_at) {|value| value.except(:posted_at)}
    end

    # ⚠ **枠ごとの `key` が未来なら `yield` で書き換え、全体の `key` を残った枠の最新に引き直す。**
    def forget_future_posts(record, time, key)
      posts = record[:posts].is_a?(Hash) ? record[:posts] : {}
      kept = posts.to_h do |name, value|
        next [name, value] unless value.is_a?(Hash) && future?(value[key], time)
        [name, yield(value)]
      end
      cleaned = posts.empty? ? record : record.merge(posts: kept)
      return cleaned unless future?(cleaned[key], time)
      latest = kept.values.filter_map {|v| parse_time(v[key]) if v.is_a?(Hash)}.max
      return cleaned.except(key) unless latest
      return cleaned.merge(key => latest.getutc.iso8601)
    end
  end
end
