module Makoto
  # 返事の途中で引く外の口（記憶の Mastodon・道具の cure-api）の待ち方（#680 の B1）。
  # ⚠ `config` は取り込む側のもの（`Package`）。
  #
  # 🔴 **短く待ってリトライしない。引けなかったら、しばらく引きに行かない**。⚠⚠ 返事のスレッドは 1 本なので、外が
  # 遅いと後ろのメンションまで詰まり、実況の窓では deadline で捨てられる（LLM の費用はかかった後）。既定の
  # `/http/timeout/seconds: 30`・`retry.limit: 3` のままだと、1 つの口で 2 分待ちうる。
  module ChatLookup
    private

    # 外の口の待ちを短くし、リトライしない（→ モジュールの冒頭）。
    def quick(http)
      http.timeout = config['/chat/lookup/timeout'].to_i
      http.retry_limit = 0
      return http
    end

    # 引けなかったときから `/chat/lookup/backoff` のあいだか。
    def backing_off?(failed_at, now = Time.now)
      return false unless failed_at
      return (now - failed_at) < lookup_backoff
    end

    def lookup_backoff
      value = config['/chat/lookup/backoff']
      seconds = Fugit::Duration.parse(value.to_s)&.to_sec
      return seconds if seconds&.positive?
      raise Ginseng::ConfigError, "chat: bad lookup backoff '#{value}'"
    end
  end
end
