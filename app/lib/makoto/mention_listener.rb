require 'net/http'

module Makoto
  # メンションを Mastodon の Streaming API（SSE）で受ける（#29）。⚠ **受けてログに出すまで** —
  # 応答を作るのは #18。
  #
  # ## 🔴 WebSocket ではなく SSE（2026-11-07・オーナー判断）
  #
  # ⚠⚠ **モロヘイヤの `Listener`（`faye-websocket` ＋ EventMachine）は移さない。**`EM.run` は
  # ブロックするので、**スケジューラ（rufus）と同じ常駐に同居させる工夫が要る。**SSE なら
  # **標準の `Net::HTTP` で長い GET を読むだけ**で、**gem も足さない。**
  # ⚠ **Streaming API に決め打つ**こと（→ docs「入出力の非対称性」）は変わらない。
  #
  # ## 常駐の中の別スレッドで受ける
  #
  # - 🔴 **切れたら繋ぎ直す。**間隔は指数で延ばし、`/streaming/retry/max` で頭打ち。
  #   ⚠ **一度でも何か受けたら間隔を戻す**（長く繋がっていた接続がサーバーの再起動で切れたときに、
  #   前の失敗の分まで待たない）
  # - 🔴 **諦めて常駐を落とさない。**⚠⚠ **モロヘイヤの `Listener` は最大リトライで `exit 1`
  #   するが、MAKOTO は投稿も同じ常駐で回している** — **受信が落ちたせいで朝挨拶が出なくなる
  #   形を作らない。**⚠ 代わりに `makoto status` が警告を出す（→ `Health#stream_warnings`）
  # - 🔴 **「繋がっているが何も受けていない」を検知する。**⚠ Mastodon は無通信でも 15 秒ごとに
  #   `:thump` を流すので、**何か届くたびに痕跡（`Heartbeat.record_stream`）を書く。**
  #   ⚠⚠ **読み取りに期限を付ける**（`READ_TIMEOUT`）— **黙って死んだ接続を待ち続けない**
  # - 🔴 **止めたらちゃんと終わる**（孤児を残さない）。⚠⚠ **`stop` は TERM の trap から呼ばれる**
  #   ので、**Mutex を掴まない**（trap の中では `ThreadError`）。スレッドを殺して待つだけ
  class MentionListener
    include Package

    # ⚠⚠ **`:thump`（15 秒ごと）の 4 回分。**届かなければ死んだ接続とみなして繋ぎ直す。
    READ_TIMEOUT = 60
    OPEN_TIMEOUT = 30

    # ⚠ **痕跡を書く間隔の下限（秒）。**⚠⚠ **届くたびに書くと、Heartbeat の鍵を tick と
    # 奪い合う**（`:thump` だけで 1 時間 240 回）。⚠ 検知の閾値（`/streaming/stale`）より十分短いこと。
    RECORD_INTERVAL = 30

    # SSE の Content-Type（#616）。
    EVENT_STREAM = 'text/event-stream'.freeze

    # 止めるときに待つ長さ（秒）。
    JOIN_TIMEOUT = 5

    attr_reader :thread, :failures

    # 繋がったら呼ぶ（取りこぼしに追いつく・#610 → `MentionCatchUp`）。⚠ 返事をしないなら nil。
    attr_writer :catch_up

    # @param service [MastodonService] ⚠ テストが差し替える
    # @param opener [#call] `(uri, headers) {|chunk| ...}` で塊を渡す。⚠ **テストが差し替える**
    #   （切断の注入）
    # @param sleeper [#call] 待ち。⚠ テストが差し替える
    # @param handler [#call, nil] メンションを受けたときに呼ぶ（#18 が繋ぐ）
    # @param follower [FollowSync] フォローの通知を渡す先（一覧に足す・返す → #510 / #606）。⚠ テストが差し替える
    def initialize(service: nil, opener: nil, sleeper: nil, handler: nil, follower: nil)
      @service = service
      @follower = follower
      @opener = opener || method(:open_stream)
      @sleeper = sleeper || ->(seconds) {sleep(seconds)}
      @handler = handler
      @failures = 0
      @stopping = false
      @recorded_at = nil
    end

    def self.enabled?
      return Config.instance['/streaming/enabled'] == true
    end

    def start
      return nil unless self.class.enabled?
      @thread ||= Thread.new do
        Thread.current.name = 'makoto-stream'
        run
      end
      return @thread
    end

    # ⚠ **trap から呼ばれる**（→ クラスの冒頭）。
    def stop
      @stopping = true
      return nil unless @thread
      @thread.kill
      @thread.join(JOIN_TIMEOUT)
      return nil
    rescue ThreadError
      return nil
    end

    def stopping?
      return @stopping
    end

    # 繋ぎ、切れたら待って繋ぎ直す。⚠ **止められるまで戻らない。**
    def run
      until stopping?
        listen
        break if stopping?
        @sleeper.call(backoff)
      end
    end

    # 1 回繋いで、切れるまで読む。⚠ **例外を上げない**（切れ方を数えて戻る）。
    def listen
      parser = ServerSentEvents.new
      @connected = false
      uri = service.streaming_uri
      logger.info(stream: 'connect', host: uri.host, failures: @failures)
      @opener.call(uri, service.streaming_headers) do |chunk|
        receive(chunk, parser)
      end
      @failures += 1
      logger.warn(stream: 'closed', failures: @failures)
    rescue => e
      @failures += 1
      log_failure(e)
    end

    # 次に繋ぐまでの秒数。`base * 2 ** (n - 1)` を `max` で頭打ち。
    def backoff
      base = duration('/streaming/retry/base')
      max = duration('/streaming/retry/max')
      return [base * (2**([@failures, 1].max - 1)), max].min
    end

    # 塊が 1 つ届いた。
    #
    # 🔴 **繋がって最初に何か届いたら、取りこぼしに追いつく**（#610）。⚠ 繋ぐ前に引くと、引いてから繋がるまでの
    # 分を落とす。後に引けば、重なった分は返事の側（`seen?`）が畳む。
    def receive(chunk, parser)
      @failures = 0
      record_alive
      unless @connected
        @connected = true
        @catch_up&.call
      end
      parser.feed(chunk) {|event| dispatch(event)}
    end

    # ⚠ **見るのは通知のうちメンションとフォローだけ**（お気に入りなどは捨てる）。
    def dispatch(event)
      return unless event.name == 'notification'
      notification = JSON.parse(event.data)
      return unless notification.is_a?(Hash)
      case notification['type']
      when 'mention' then on_mention(notification)
      when 'follow' then on_follow(notification)
      end
    rescue JSON::ParserError => e
      # ⚠⚠ **例外そのものを渡さない**（PR #586 の Codex の P2）— **`JSON::ParserError` の文は入力の
      # 抜粋を含む**ので、メンバーの書いた本文がログに漏れる（`on_mention` で本文を出さないのと同じ理由）。
      logger.warn(stream: 'notification', message: 'unreadable payload', error_class: e.class.name)
    end

    # ⚠⚠ **本文はログに出さない**（メンバーの書いたもの）。⚠ 長さと宛先だけ。
    def on_mention(notification)
      status = notification['status'] || {}
      logger.info(
        stream: 'mention',
        notification_id: notification['id'],
        status_id: status['id'],
        acct: notification.dig('account', 'acct'),
        visibility: status['visibility'],
        length: status['content'].to_s.length,
      )
      @handler&.call(notification)
    rescue => e
      # ⚠⚠ **応答の側の失敗で受信を止めない。**
      logger.error(stream: 'mention', error: e)
      report_error(e, stream: 'mention')
    end

    # 🔴 **新しいフォロワーをすぐ一覧に足し、フォローを返す**（#510 の門・#606 → `FollowSync#on_follow`）。
    # ⚠ 失敗しても受信は止めない。
    def on_follow(notification)
      account = notification['account']
      return unless account.is_a?(Hash) && account['id']
      logger.info(stream: 'follow', notification_id: notification['id'], acct: account['acct'])
      follower.on_follow(account)
    end

    private

    def follower
      @follower ||= FollowSync.new
      return @follower
    end

    def service
      @service ||= MastodonService.new
      return @service
    end

    # ⚠ **失効（401 / 403）は error・それ以外は warn。**⚠⚠ **どちらでも繋ぎ直しは続ける** —
    # トークンを差し替えて再起動するまで、間隔の上限で叩き続ける。
    def log_failure(error)
      if error.is_a?(Ginseng::AuthError)
        logger.error(stream: 'failed', failures: @failures, message: 'token is not valid',
          error: error)
      else
        logger.warn(stream: 'failed', failures: @failures, error_class: error.class.name,
          error: error)
      end
    end

    # 痕跡に受信の時刻を書く。⚠ **書けなくても受信は止めない**（→ `MakotoDaemon#record_start`）。
    def record_alive
      clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @recorded_at && clock - @recorded_at < RECORD_INTERVAL
      @recorded_at = clock
      Heartbeat.record_stream
    rescue => e
      logger.error(stream: 'heartbeat', error: e)
    end

    def duration(key)
      seconds = Fugit::Duration.parse(config[key].to_s)&.to_sec
      raise Ginseng::ConfigError, "streaming: bad #{key} '#{config[key]}'" unless seconds&.positive?
      return seconds
    end

    # 🔴 **SSE の口を開けて、届いた塊を渡す。**⚠ 2xx 以外は分類して上げる。
    # ⚠⚠ **2xx でも SSE でなければ上げる**（#616）— 前段がメンテナンスの HTML を 200 で返して閉じると、
    # 本文を `receive` に渡した時点で失敗の回数を 0 に戻し、受信の痕跡を書いてしまう
    # （`makoto status` が緑のまま、最短の間隔で繋ぎ直し続ける）。**本文を読む前に弾く。**
    def open_stream(uri, headers, &)
      Net::HTTP.start(uri.host, uri.port,
        use_ssl: uri.scheme == 'https',
        open_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT) do |http|
        http.request(Net::HTTP::Get.new(uri, headers)) do |response|
          raise_for(response) unless response.is_a?(Net::HTTPSuccess)
          raise_unless_event_stream(response)
          response.read_body(&)
        end
      end
    end

    def raise_unless_event_stream(response)
      type = response['Content-Type'].to_s.split(';').first.to_s.strip.downcase
      return if type == EVENT_STREAM
      raise Ginseng::GatewayError, "streaming returned '#{type}', not #{EVENT_STREAM}"
    end

    def raise_for(response)
      status = response.code.to_i
      klass = MastodonService::PERMANENT_STATUSES[status] || Ginseng::GatewayError
      raise klass, "streaming returned #{status}"
    end
  end
end
