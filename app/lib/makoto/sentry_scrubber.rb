require 'syslog/logger'

module Makoto
  # Sentry へ送るイベントから資格情報を落とす（#28）。
  #
  # 🔴 **ログでは伏せている値を、例外イベントとして素通しさせない。**⚠⚠ **`send_default_pii`
  # の既定 false が守るのはリクエストヘッダ等**で、**アプリが自分で例外メッセージへ埋めた値は
  # 対象外。**
  #
  # ⚠⚠ **マスクの正本は `Ginseng::Logger`**（`/logger/mask_fields` と上流の既定）。🔴 **ここで
  # 同等品を書かない** — **対象の列がログ側と 2 か所に分かれて必ずズレる**（#216 で `makoto config`
  # が踏んだ形）。⚠ **上流の `mask` / `mask_url` をそのまま呼ぶ。**
  #
  # ⚠ **tomato-shrieker の `SentryScrubber`（pooza/tomato-shrieker#1467 / #1538 / #1549）の写し。**
  # 同じ ginseng アプリで、同じ穴を先に塞いでいる。
  class SentryScrubber
    include Package

    # ⚠ **ここで logger を掴み、マスクが効くことを 1 回確かめる。**🔴 **読めなければ例外で、
    # Sentry ごと立ち上がらない（fail closed）** — ⚠⚠ **読めないまま `before_send` に入ると
    # 「マスク対象ゼロ ＝ 素通し」で送り続ける。**
    def initialize
      @logger = logger
      @logger.mask_url('https://example.com/?access_token=probe')
    end

    # ⚠⚠ **必ず event を返すこと。**`before_send` が `Sentry::ErrorEvent` 以外を返すと、
    # イベントは破棄される（sentry-ruby 7.0.0 の `client.rb`）。
    def scrub(event)
      scrub_exceptions(event)
      event.message = mask(event.message) if event.message.is_a?(String)
      event.transaction = mask(event.transaction) if event.transaction.is_a?(String)
      event.extra = mask(event.extra)
      event.tags = mask(event.tags)
      event.contexts = mask(event.contexts)
      event.user = mask(event.user)
      scrub_breadcrumbs(event)
      return event
    rescue => e
      # 🔴 **fail closed。**マスクを通せなかったイベントは送らない。
      report_drop(e)
      return nil
    end

    private

    # 🔴 **`warn` で出さない。**⚠⚠ **`bin/makoto_daemon.rb` が `$stderr` を `/dev/null` に
    # つなぐ**ので、本番では丸ごと消える — **「Sentry へ何も届かないのに誰も気づけない」になる。**
    def report_drop(error)
      @logger.error(sentry: 'before_send', message: 'event dropped (scrub failed)', error: error)
    rescue => e
      report_drop_fallback(error, e)
    end

    # 🔴 **最後の 1 手はマスク経路に依存させない。**⚠⚠ **scrub が落ちた原因がマスク設定なら、
    # `@logger.error` も同じ理由で落ちる。**⚠ **出すのは例外のクラス名だけ**（メッセージを
    # 載せると、伏せるはずだった値をマスク無しで書くことになる）。
    def report_drop_fallback(error, log_error)
      ::Syslog::Logger.new(Package.name).error(
        'sentry before_send: event dropped (scrub failed):' \
          " #{error.class} (logging failed: #{log_error.class})",
      )
    rescue
      return nil
    end

    # ⚠ **例外メッセージ本体。**`SingleExceptionInterface#value` だけが書ける。
    def scrub_exceptions(event)
      entries = event.exception&.values
      return unless entries
      entries.each do |entry|
        entry.value = mask(entry.value) if entry.value.is_a?(String)
      end
    end

    def scrub_breadcrumbs(event)
      event.breadcrumbs&.buffer&.each do |crumb|
        next unless crumb
        crumb.message = mask(crumb.message) if crumb.message.is_a?(String)
        crumb.data = mask(crumb.data) if crumb.data.is_a?(Hash)
      end
    end

    # ⚠ `Ginseng::Logger#mask` は Hash / Array / String を再帰的に処理し、`mask_fields` の
    # キーは値ごと落とす。String は `mask_url` を通る。
    def mask(value)
      return value unless value.is_a?(String) || value.is_a?(Hash) || value.is_a?(Array)
      return @logger.mask(value)
    end
  end
end
