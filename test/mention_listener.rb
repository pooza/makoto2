module Makoto
  class MentionListenerTest < TestCase
    FakeService = Struct.new(:uri) do
      def streaming_uri
        return URI.parse(uri)
      end

      def streaming_headers
        return {'Authorization' => 'Bearer x'}
      end
    end

    setup do
      clear
    end

    teardown do
      clear
    end

    def clear
      FileUtils.rm_f(Heartbeat.path)
      FileUtils.rm_f(Heartbeat.lock_path)
    end

    def service
      return FakeService.new('https://streaming.example.com/api/v1/streaming/user/notification')
    end

    def mention(id: '1', type: 'mention')
      payload = {
        id: id,
        type: type,
        account: {acct: 'cure_sword'},
        status: {id: "s#{id}", visibility: 'public', content: '<p>真琴さん</p>'},
      }
      return "event: notification\ndata: #{payload.to_json}\n\n"
    end

    # `opener` に渡す段取り。⚠ **1 回目は落ち、2 回目は届いてから切れ、3 回目で止める。**
    def scripted_opener(steps, listener_ref)
      return lambda do |_uri, _headers, &block|
        step = steps.shift
        listener_ref[:listener].stop if steps.empty?
        raise step if step.is_a?(Exception)
        Array(step).each {|chunk| block.call(chunk)}
      end
    end

    def test_a_mention_reaches_the_handler
      received = []
      listener = MentionListener.new(service: service, handler: ->(n) {received.push(n)})
      listener.receive(mention, ServerSentEvents.new)

      assert_equal(['1'], received.map {|n| n['id']})
      assert_equal('cure_sword', received.first.dig('account', 'acct'))
    end

    # ⚠ **メンション以外の通知は捨てる。**
    def test_other_notifications_are_dropped
      received = []
      listener = MentionListener.new(service: service, handler: ->(n) {received.push(n)})
      parser = ServerSentEvents.new
      listener.receive(mention(type: 'favourite'), parser)
      listener.receive("event: update\ndata: {}\n\n", parser)

      assert_empty(received)
    end

    # 🔴 **フォローの通知で、フォロワーの一覧へすぐ足す**（#510 の門）。
    def test_a_follow_is_added_to_the_roster
      roster = FollowerRoster.new(fetcher: -> {['1']})
      roster.refresh
      listener = MentionListener.new(service: service, roster: roster)
      payload = {id: 'n1', type: 'follow', account: {id: '9', acct: 'new_fan'}}.to_json
      listener.receive("event: notification\ndata: #{payload}\n\n", ServerSentEvents.new)

      assert_true(roster.include?('9'))
    end

    # ⚠⚠ **壊れた本文の抜粋をログに出さない**（PR #586 の Codex の P2）。
    def test_a_broken_payload_does_not_raise
      listener = MentionListener.new(service: service)
      logged = []
      listener.logger.define_singleton_method(:warn) {|payload| logged.push(payload)}

      assert_nothing_raised do
        listener.receive("event: notification\ndata: {secret words\n\n", ServerSentEvents.new)
      end
      assert_equal(1, logged.size)
      assert_equal('JSON::ParserError', logged.first[:error_class])
      assert_false(logged.first.key?(:error))
      assert_not_include(logged.first.to_s, 'secret')
    end

    # 🔴 **応答の側の失敗で受信を止めない**（#18 が繋ぐ口）。
    def test_a_failing_handler_does_not_raise
      listener = MentionListener.new(service: service, handler: ->(_) {raise 'boom'})

      assert_nothing_raised {listener.receive(mention, ServerSentEvents.new)}
    end

    def test_backoff_grows_and_is_capped
      listener = MentionListener.new(service: service)
      delays = [1, 2, 3, 10].map do |count|
        listener.instance_variable_set(:@failures, count)
        listener.backoff
      end

      assert_equal([5, 10, 20, 300], delays)
    end

    # 🔴 **切断を注入して、繋ぎ直すこと・届いたら間隔を戻すこと**（#29 の完了条件）。
    def test_reconnects_after_failures
      waits = []
      received = []
      ref = {}
      steps = [Ginseng::GatewayError.new('boom'), Errno::ECONNRESET.new, [mention], [mention(id: '2')]]
      listener = MentionListener.new(
        service: service,
        opener: scripted_opener(steps, ref),
        sleeper: ->(seconds) {waits.push(seconds)},
        handler: ->(n) {received.push(n['id'])},
      )
      ref[:listener] = listener
      listener.run

      assert_equal(['1', '2'], received)
      # ⚠ 落ちるたびに延び（5 → 10）、届いてから切れたら base に戻る（5）。
      assert_equal([5, 10, 5], waits)
      assert_true(listener.stopping?)
    end

    # 🔴 **止めたら終わる**（孤児を残さない）。⚠ **読み取りの途中でも、待ちの途中でも。**
    def test_stop_ends_the_thread
      config['/streaming/enabled'] = true
      opener = ->(_uri, _headers, &_block) {sleep}
      listener = MentionListener.new(service: service, opener: opener)
      thread = listener.start
      sleep(0.05)
      listener.stop

      assert_false(thread.alive?)
    end

    def test_disabled_does_not_start
      config['/streaming/enabled'] = false
      listener = MentionListener.new(service: service)

      assert_nil(listener.start)
    end

    # 🔴 **届いたら痕跡に書く**（「繋がっているが何も受けていない」の検知）。⚠ **`:thump` も数える。**
    def test_a_thump_is_recorded
      listener = MentionListener.new(service: service)
      listener.receive(":thump\n", ServerSentEvents.new)

      assert_not_nil(Heartbeat.streamed_at)
    end

    # ⚠ **書く間隔に下限がある**（Heartbeat の鍵を tick と奪い合わない）。
    def test_records_are_throttled
      listener = MentionListener.new(service: service)
      parser = ServerSentEvents.new
      listener.receive(":thump\n", parser)
      first = Heartbeat.streamed_at
      FileUtils.rm_f(Heartbeat.path)
      listener.receive(":thump\n", parser)

      assert_not_nil(first)
      assert_nil(Heartbeat.streamed_at)
    end

    # 🔴 **2xx 以外は分類して上げる**（→ `listen` が数えて繋ぎ直す）。
    def test_open_stream_classifies_errors
      stub_request(:get, service.uri).to_return(status: 401)
      listener = MentionListener.new(service: service)

      assert_raise(Ginseng::AuthError) do
        listener.send(:open_stream, service.streaming_uri, service.streaming_headers) {|_| nil}
      end
    end

    def test_open_stream_passes_the_body
      stub_request(:get, service.uri)
        .with(headers: {'Authorization' => 'Bearer x'})
        .to_return(status: 200, body: ":thump\n#{mention}")
      received = []
      listener = MentionListener.new(service: service, handler: ->(n) {received.push(n['id'])})
      parser = ServerSentEvents.new
      listener.send(:open_stream, service.streaming_uri, service.streaming_headers) do |chunk|
        listener.receive(chunk, parser)
      end

      assert_equal(['1'], received)
    end
  end
end
