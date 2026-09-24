module Makoto
  # Sentry へ送るペイロードから資格情報が落ちていること（#28）。
  #
  # ⚠⚠ **「マスク処理を呼んでいる」ではなく「出力に含まれていない」を見る。**呼んでいるか
  # どうかは、対象の列がズレていれば通ってしまう。
  # ⚠ **tomato-shrieker の `SentryScrubberTest` の写し**（makoto2 が持つ資格情報の形に合わせた）。
  class SentryScrubberTest < TestCase
    TOKEN = 'SUPERSECRETTOKEN'.freeze
    # ⚠ **URL に埋まったトークン**（`MastodonService` の例外メッセージに URL が載る形）。
    TOKEN_URL = "https://st2.precure.ml/api/v1/statuses?access_token=#{TOKEN}".freeze
    # ⚠ 既定にも makoto2 の設定にも無いキー。既にマスク対象のキーを使うと判定にならない。
    PROBE_FIELD = 'makoto_reload_probe'.freeze
    PROBE_VALUE = 'PROBEPLAINTEXT'.freeze
    # ⚠ **鍵は userinfo のユーザ名側だけに入る**（`user:pass` の形ではないので、URL のマスクに当たらない）。
    DSN = 'https://publickey@o1.ingest.sentry.io/456'.freeze

    def setup
      super
      @scrubber = SentryScrubber.new
    end

    # 🔴 **例外メッセージに埋まった URL のトークン**を落とす。
    def test_scrub_exception_message
      event = error_event(Ginseng::GatewayError.new("Bad response 502 (#{TOKEN_URL})"))
      scrubbed = @scrubber.scrub(event)

      assert_not_nil(scrubbed, 'イベントを落としてはいけない')
      assert_not_include(payload(scrubbed), TOKEN)
    end

    # ⚠ **extra / tags は `mask_fields` のキーごと落ちる**（`token` / `authorization` / `dsn`）。
    def test_scrub_extra_and_tags
      event = error_event(StandardError.new('boom'))
      event.extra = {token: TOKEN, authorization: "Bearer #{TOKEN}", post: 'song'}
      event.tags = {dsn: "https://#{TOKEN}@example.ingest.sentry.io/1"}
      scrubbed = payload(@scrubber.scrub(event))

      assert_not_include(scrubbed, TOKEN)
      assert_include(scrubbed, 'song', '無関係な値は残す')
    end

    # 🔴 **許可リストに無いタグは値ごと落とす**（#347）。
    #
    # ⚠⚠ **許可リストを掛けられるのはタグだけ** — **例外メッセージは自由文なので列挙できず、
    # 長さで切っても守れない**（**原稿 606 本の中央値は 28 字**）。
    def test_tags_outside_the_allowlist_are_dropped
      event = error_event(StandardError.new('boom'))
      event.tags = {post: 'song', phase: 'notify', daemon: 'makoto2', body: PROBE_VALUE}
      scrubbed = @scrubber.scrub(event)

      assert_equal(SentryScrubber::ALLOWED_TAGS, scrubbed.tags.keys.map(&:to_s))
      assert_not_include(payload(scrubbed), PROBE_VALUE, '許可リストの外は値ごと落とす')
    end

    # 🔴 **自由文は上限で切る**（#347）。⚠⚠ **これは漏れ止めではなく量の歯止め** —
    # **実測の例外メッセージは 16〜57 字**なので、**150 字は 50 日で一度も当たらない。**
    def test_a_long_exception_message_is_truncated
      event = error_event(StandardError.new('あ' * 400))
      # ⚠ **`sentry-ruby` は末尾に ` (StandardError)` を足す**ので、**素の 400 字ではない。**
      original = event.exception.values.first.value.length
      value = @scrubber.scrub(event).exception.values.first.value

      assert_equal('あ' * SentryScrubber::MAX_TEXT_LENGTH, value[0, SentryScrubber::MAX_TEXT_LENGTH])
      # ⚠ **落とした字数を残す**（🔴 **黙って切ると「短いメッセージ」に見える**）。
      assert_include(value, "…(#{original - SentryScrubber::MAX_TEXT_LENGTH} chars truncated)")
    end

    # ⚠ **実測の長さのメッセージは 1 字も触らない**（🔴 **本物を切ったら調査に使えない**）。
    # ⚠⚠ **`bydo` の journal 50 日で最長の 57 字がこれ**（＋ `sentry-ruby` が足すクラス名）。
    def test_a_message_within_the_limit_is_untouched
      message = "undefined method 'start_with?' for an instance of Integer"
      event = error_event(StandardError.new(message))
      expected = event.exception.values.first.value

      assert_operator(expected.length, :<, SentryScrubber::MAX_TEXT_LENGTH)
      assert_equal(expected, @scrubber.scrub(event).exception.values.first.value)
    end

    # 🔴 **切るのはマスクの後**（#347）。⚠⚠ **先に切ると URL が途中で終わり、`mask_url` が
    # URL と認めずにトークンの一部が平文で残る。**
    def test_a_token_beyond_the_limit_is_masked_before_truncation
      event = error_event(Ginseng::GatewayError.new("#{'x' * 200} #{TOKEN_URL}"))

      assert_not_include(payload(@scrubber.scrub(event)), TOKEN)
    end

    # ⚠ **資格情報を含まない情報まで消さない**（消すと調査に使えなくなる）。
    def test_scrub_keeps_diagnostics
      event = error_event(Ginseng::GatewayError.new('Bad response 503 (https://st2.precure.ml/api/v1/statuses)'))
      scrubbed = payload(@scrubber.scrub(event))

      assert_include(scrubbed, '/api/v1/statuses')
      assert_include(scrubbed, 'Bad response 503')
    end

    # 🔴 **稼働中の `Config#reload` が、掴んだままの logger にも効く**（tomato-shrieker#1538）。
    def test_scrub_follows_config_reload
      assert_include(scrubbed_probe, PROBE_VALUE, '前提: まだマスク対象ではない')

      with_mask_field(PROBE_FIELD) do
        assert_not_include(scrubbed_probe, PROBE_VALUE, 'reload が掴んだままの logger に効いていない')
      end
    end

    # 🔴 **fail closed。**マスクを通せなかったイベントは送らない。
    def test_scrub_drops_event_when_mask_fails
      assert_nil(@scrubber.scrub(broken_event))
    end

    # 🔴 **落としたことをログに残す**（`warn` は本番で `/dev/null`）。
    def test_scrub_logs_when_event_is_dropped
      logged = []
      @scrubber.instance_variable_get(:@logger).define_singleton_method(:error) {|arg| logged.push(arg)}
      @scrubber.scrub(broken_event)

      assert_equal(1, logged.size, 'イベントを黙って捨てている')
      assert_equal('before_send', logged.first[:sentry])
    end

    # 🔴 **logger 自身が落ちても、マスク経路に依存しない予備へ残す**（tomato-shrieker#1549）。
    def test_scrub_reports_drop_when_logger_fails
      @scrubber.instance_variable_get(:@logger).define_singleton_method(:error) {|_arg| raise 'logger boom'}
      fallback = []
      @scrubber.define_singleton_method(:report_drop_fallback) do |error, log_error|
        fallback.push([error.class, log_error.class])
      end

      assert_nothing_raised {assert_nil(@scrubber.scrub(broken_event))}
      assert_equal(1, fallback.size, 'logger が落ちたときに何も残っていない')
    end

    # ⚠⚠ **予備の出口はクラス名だけ**（メッセージを載せると伏せるはずの値が素で出る）。
    def test_report_drop_fallback_emits_class_names_only
      written = []
      sink = Object.new
      sink.define_singleton_method(:error) {|arg| written.push(arg)}
      Syslog::Logger.define_singleton_method(:new) {|*| sink}
      begin
        @scrubber.send(:report_drop_fallback, Ginseng::GatewayError.new(TOKEN_URL), RuntimeError.new(TOKEN))
      ensure
        Syslog::Logger.singleton_class.remove_method(:new)
      end

      assert_equal(1, written.size)
      assert_include(written.first, 'Ginseng::GatewayError')
      assert_not_include(written.first, TOKEN)
    end

    # ⚠ **DSN が無ければ初期化しない**（開発機・CI・テスト）。⚠ **送る口も何もしない。**
    def test_nothing_is_sent_without_a_dsn
      assert_nil(Makoto.sentry_dsn)
      assert_false(Sentry.initialized?)
      assert_nil(Object.new.extend(Package).report_error(StandardError.new('boom'), post: 'song'))
    end

    # ⚠ **`traces_sample_rate` が無くても 0 に倒す**（Codex の P2）。
    def test_traces_sample_rate_defaults_to_zero
      config.delete('/sentry/traces_sample_rate')

      assert_equal(0, Makoto.sentry_traces_sample_rate)
    ensure
      config.reload
    end

    # 🔴 **DSN があるときの配線は、ここでしか通らない**（v0.6.0 のリリース前レビュー・黄）。
    # ⚠⚠ **`before_send` に scrubber を挿す行を消しても、これが無ければ緑のまま通る。**
    def test_setup_with_a_dsn_wires_the_scrubber
      with_dsn(DSN) do
        Makoto.setup_sentry

        assert_true(Sentry.initialized?)
        assert_not_nil(Sentry.configuration.before_send, 'マスクが配線されていない')
        scrubbed = Sentry.configuration.before_send.call(
          error_event(Ginseng::GatewayError.new("Bad response 502 (#{TOKEN_URL})")), nil
        )

        assert_not_include(payload(scrubbed), TOKEN)
      end
    end

    # 🔴 **外向きの要求に DSN の鍵を載せない**（v0.6.0 のリリース前レビュー・黄）。
    # ⚠⚠ **既定の `true` は `Baggage: ...sentry-public_key=<鍵>` を投稿 1 本ごとに付ける。**
    # ⚠ **`traces_sample_rate` が 0 でも止まらない**ので、ここで明示的に落とす。
    def test_setup_does_not_propagate_traces
      with_dsn(DSN) do
        Makoto.setup_sentry

        assert_false(Sentry.configuration.propagate_traces)
      end
    end

    # 🔴 **フレームのローカル変数を送らない**（#347）。
    #
    # ⚠⚠ **`PostingJob` の `rescue` の内側には `text`（投稿本文）が居る。**
    # ⚠ **既定は false だが明示を留める** — 🔴 **`propagate_traces` は既定が危ない側だった。**
    def test_setup_does_not_collect_local_variables
      with_dsn(DSN) do
        Makoto.setup_sentry

        assert_false(Sentry.configuration.data_collection.collect_stack_frame_variables?)
      end
    end

    # ⚠ **breadcrumb は 1 つも積んでいない**ので、**運ぶ容れ物も開けない**（#347）。
    def test_setup_keeps_no_breadcrumbs
      with_dsn(DSN) do
        Makoto.setup_sentry

        assert_equal(0, Sentry.configuration.max_breadcrumbs)
      end
    end

    # 🔴 **初期化が落ちたことを黙って捨てない**（v0.6.0 のリリース前レビュー・赤）。
    # ⚠⚠ **`bin/makoto_daemon.rb` が `require 'makoto'` の前に `$stderr` を `/dev/null` へ繋ぐ**
    # ので、**`warn` では本番に 1 行も残らない。**
    def test_setup_logs_when_initialization_fails
      logged = []
      original = $stderr
      $stderr = StringIO.new
      sink = Object.new
      sink.define_singleton_method(:error) {|arg| logged.push(arg)}
      Logger.define_singleton_method(:new) {|*| sink}
      begin
        with_dsn("#{DSN}\n") {assert_nothing_raised {Makoto.setup_sentry}}
        written = $stderr.string
      ensure
        Logger.singleton_class.remove_method(:new)
        $stderr = original
      end

      assert_false(Sentry.initialized?, '壊れた DSN で立ち上げない（fail closed）')
      assert_empty(written, 'stderr は本番で /dev/null へ落ちる')
      assert_equal(1, logged.size, '初期化の失敗が 1 行も残っていない')
      assert_equal('init', logged.first[:sentry])
      assert_not_include(logged.first.to_s, 'publickey', 'DSN を載せない')
    end

    # 🔴 **最後の 1 手で起動を巻き込まない**（Codex の P2）。⚠⚠ **`setup_sentry` の rescue から
    # 呼ばれる**ので、**syslog も使えない箱でここが例外を上げると、観測の行が常駐を落とす。**
    def test_setup_error_fallback_never_raises
      Syslog::Logger.define_singleton_method(:new) {|*| raise 'syslog boom'}
      begin
        assert_nothing_raised do
          assert_nil(Makoto.report_sentry_setup_error_fallback(RuntimeError.new('boom'), RuntimeError.new('log')))
        end
      ensure
        Syslog::Logger.singleton_class.remove_method(:new)
      end
    end

    # 🔴 **送れるかを 3 つに分けて言う**（#347）。⚠⚠ **`https://` だが DSN でない値は、初期化に
    # 成功して 1 件も送らない**（Web UI のプロジェクトの URL を貼った形）。
    def test_sentry_state
      assert_equal(:off, Makoto.sentry_state)
      with_dsn(DSN) do
        Makoto.setup_sentry

        assert_equal(:on, Makoto.sentry_state)
      end
      with_dsn('https://sentry.example.com/organizations/x/projects/y/') do
        logged = capture_logger_errors {Makoto.setup_sentry}

        assert_equal(:misconfigured, Makoto.sentry_state)
        assert_equal(['initialized but will not send (the DSN is not valid)'], logged.map {|v| v[:message]})
        assert_not_include(logged.to_s, 'sentry.example.com', 'DSN を載せない')
      end
    end

    # 🔴 **スキーマが DSN の形まで見る**（#347）。
    def test_the_schema_rejects_a_project_url
      pattern = Regexp.new(config.schema.dig('properties', 'sentry', 'properties', 'dsn', 'pattern'))

      assert_match(pattern, DSN)
      assert_no_match(pattern, 'https://sentry.example.com/organizations/x/projects/y/')
    end

    # 🔴 **DSN が空でも警告を出さない。**⚠⚠ **`dsn: null` は `Config#[]` で例外になる**ので、
    # 素で読むとすべての起動が「Sentry initialization skipped」を出していた。
    def test_setup_without_a_dsn_is_silent
      original = $stderr
      $stderr = StringIO.new
      Makoto.setup_sentry

      assert_empty($stderr.string)
      assert_false(Sentry.initialized?)
    ensure
      $stderr = original
    end

    private

    def capture_logger_errors
      logged = []
      # ⚠ **`SentryScrubber.new` も `Logger.new` を掴む**ので、`error` 以外は黙って受ける。
      sink = Class.new(BasicObject) do
        define_method(:error) {|arg| logged.push(arg)}
        define_method(:method_missing) {|*| nil}
        define_method(:respond_to_missing?) {|*| true}
      end.new
      Logger.define_singleton_method(:new) {|*| sink}
      yield
      return logged
    ensure
      Logger.singleton_class.remove_method(:new)
    end

    def broken_event
      event = error_event(StandardError.new('boom'))
      event.define_singleton_method(:extra) {raise 'boom'}
      return event
    end

    # ⚠ **scrubber は setup で作ってある**（＝設定を変える前に掴んだ logger）。
    def scrubbed_probe
      event = error_event(StandardError.new('boom'))
      event.extra = {PROBE_FIELD => PROBE_VALUE}
      return payload(@scrubber.scrub(event))
    end

    # マスク対象を 1 つ足して `Config#reload` する。⚠ **実在するうちいちばん強い basename へ足す。**
    def with_mask_field(field)
      key = config.basenames.find {|v| config.raw.key?(v)}
      original = config.raw[key]['logger']
      config.raw[key]['logger'] = (original || {}).deep_dup
      config.raw[key]['logger']['mask_fields'] = config['/logger/mask_fields'] + [field]
      config.reload
      yield
    ensure
      config.raw[key]['logger'] = original
      config.reload
    end

    # ⚠ **設定ではなく読み出しを差し替える**（`config['/sentry/dsn']` は `@raw` を見ないため）。
    # 🔴 **必ず `Sentry.close` する** — ⚠⚠ **初期化したままにすると、後続のテストが
    # 「DSN が無ければ何もしない」を確かめられなくなる。**
    def with_dsn(dsn)
      Makoto.define_singleton_method(:sentry_dsn) {dsn}
      return yield
    ensure
      Makoto.singleton_class.remove_method(:sentry_dsn)
      Sentry.close
    end

    def error_event(error)
      return Sentry::Client.new(sentry_configuration).event_from_exception(error)
    end

    def sentry_configuration
      configuration = Sentry::Configuration.new
      configuration.dsn = 'https://publickey@example.com/1'
      configuration.environment = 'test'
      return configuration
    end

    # ⚠ **実際に送られる形（シリアライズ後）で見る。**
    def payload(event)
      return event.to_json_compatible.to_json
    end
  end
end
