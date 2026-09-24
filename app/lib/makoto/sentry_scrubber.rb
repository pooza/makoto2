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

    # 🔴 **Sentry へ出してよいタグのキー**（#347）。
    #
    # ⚠⚠ **`report_error` のキーワード引数に渡っているのは実測でこの 3 つだけ**
    # （**呼び出しは 8 か所** — `PostingJob` ×3 / `MakotoDaemon` ×2 / `Scheduler` ×3）。
    # 🔴 **知らないキーは値ごと落とす**（fail-closed）— ⚠ **口が増えた日に
    # 「許可リストに足すのを忘れた」が、漏れではなく欠落として出る。**
    #
    # ⚠⚠ **許可リストを掛けられるのはここだけ。**🔴 **例外メッセージは自由文なので
    # 列挙できず、長さで切っても守れない** — ⚠ **原稿 606 本の中央値は 28 字**で、
    # **それを切る上限は本物の例外メッセージも切る**（2026-09-24 の実測・#347）。
    ALLOWED_TAGS = ['post', 'phase', 'daemon'].freeze

    # 自由文の上限（#347・2026-09-24）。
    #
    # 🔴🔴 **これは漏れ止めではない。**⚠⚠ **実測で範囲が重なっている**:
    #
    # | | 字 |
    # | --- | --- |
    # | 例外メッセージ（`bydo` の journal 50 日・61 件） | **16〜57**（median 16） |
    # | 原稿 606 本 | **3〜328**（median 28） |
    #
    # 🔴 **原稿を切れる上限は本物の例外メッセージも切る**ので、⚠ **どこで切っても片方を壊す。**
    # ⚠⚠ **原稿が乗る筋道を塞いでいるのは `data_collection.stack_frame_variables = false` のほう**
    # （→ `Makoto.setup_sentry`）。
    #
    # ✅ **これは「量の歯止め」** — ⚠ **150 は実測の max 57 の 2.6 倍**なので、**50 日で一度も
    # 当たらない。**🔴 **想定外に巨大なメッセージだけを切る**（**Sequel が SQL を丸ごと抱えた形**）。
    MAX_TEXT_LENGTH = 150

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
      event.message = truncate(mask(event.message)) if event.message.is_a?(String)
      event.transaction = mask(event.transaction) if event.transaction.is_a?(String)
      event.extra = mask(event.extra)
      event.tags = allow(mask(event.tags))
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
        entry.value = truncate(mask(entry.value)) if entry.value.is_a?(String)
      end
    end

    def scrub_breadcrumbs(event)
      event.breadcrumbs&.buffer&.each do |crumb|
        next unless crumb
        crumb.message = truncate(mask(crumb.message)) if crumb.message.is_a?(String)
        crumb.data = mask(crumb.data) if crumb.data.is_a?(Hash)
      end
    end

    # 🔴 **自由文を上限で切る**（#347）。
    #
    # ⚠ **マスクの後に切る。**🔴 **先に切ると URL が途中で終わり、`mask_url` が URL と
    # 認めずにトークンの一部が平文で残る。**
    #
    # ⚠⚠ **切ったことと落とした字数を残す** — 🔴 **黙って切ると「短いメッセージ」に見え、
    # 上限に当たったこと自体が分からない。**
    #
    # ⚠ **`sentry-ruby` は `value` の末尾に ` (<例外クラス>)` を足す**（実測・7.0.0）ので、
    # 🔴 **長いメッセージを切るとクラス名が落ちる。**⚠⚠ **失われはしない** —
    # **クラスは `SingleExceptionInterface#type` に別で入る。**
    def truncate(text)
      return text if text.length <= MAX_TEXT_LENGTH
      return "#{text[0, MAX_TEXT_LENGTH]}…(#{text.length - MAX_TEXT_LENGTH} chars truncated)"
    end

    # 🔴 **許可リストに無いキーは値ごと落とす**（#347）。
    #
    # ⚠ **`event.tags` のキーは Symbol でも String でも来る**ので `to_s` で揃える。
    # ⚠⚠ **Hash でなければ触らない** — **`mask` は Array や String も返しうる。**
    def allow(tags)
      return tags unless tags.is_a?(Hash)
      return tags.select {|key, _| ALLOWED_TAGS.include?(key.to_s)}
    end

    # ⚠ `Ginseng::Logger#mask` は Hash / Array / String を再帰的に処理し、`mask_fields` の
    # キーは値ごと落とす。String は `mask_url` を通る。
    def mask(value)
      return value unless value.is_a?(String) || value.is_a?(Hash) || value.is_a?(Array)
      return @logger.mask(value)
    end
  end
end
