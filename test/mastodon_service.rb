module Makoto
  class MastodonServiceTest < TestCase
    def setup
      super
      @service = MastodonService.new
      @url = "#{config['/mastodon/url']}/api/v1/statuses"
    end

    def test_post_status
      stub_request(:post, @url)
        .to_return(status: 200, headers: {'Content-Type' => 'application/json'}, body: {
          id: '114514', url: "#{config['/mastodon/url']}/@test/114514", visibility: 'public'
        }.to_json)
      status = @service.post_status('こんにちは')

      assert_equal('114514', status['id'])
      assert_requested(:post, @url, times: 1)
    end

    def test_post_status_sends_token
      stub_request(:post, @url)
        .with(headers: {'Authorization' => "Bearer #{config['/mastodon/token']}"})
        .to_return(status: 200, headers: {'Content-Type' => 'application/json'}, body: '{}')
      @service.post_status('こんにちは')

      assert_requested(:post, @url, times: 1)
    end

    # 恒久的な失敗は分類して上げ、再送しない（ginseng-core 1.15.28 以降）。
    # 無人で投稿し続けるボットが 401 を 3 回投げ直しても意味が無い。
    def test_post_status_auth_error
      stub_request(:post, @url).to_return(status: 401, body: '{}')

      assert_raise(Ginseng::AuthError) {@service.post_status('こんにちは')}
      assert_requested(:post, @url, times: 1)
    end

    def test_post_status_validate_error
      stub_request(:post, @url).to_return(status: 422, body: '{}')

      assert_raise(Ginseng::ValidateError) {@service.post_status('')}
      assert_requested(:post, @url, times: 1)
    end

    # ⚠ 再送で投稿が二重に出ないこと。**同じキーが全試行で飛ぶ**のが本体で、
    # 「キーが付いている」だけでは 3 通投稿される事故は防げない。
    def test_post_status_reuses_idempotency_key_across_retries
      config['/http/retry/seconds'] = 0
      keys = []
      stub_request(:post, @url).to_return do |request|
        keys.push(request.headers['Idempotency-Key'])
        {status: 503, body: '{}'}
      end

      assert_raise(Ginseng::GatewayError) {@service.post_status('こんにちは')}
      assert_equal(config['/http/retry/limit'], keys.length)
      assert_equal(1, keys.uniq.length)
      assert_not_nil(keys.first)
    end

    # 投稿ごとには別のキーになる（同じキーを使い回すと 2 通目が捨てられる）。
    def test_post_status_uses_fresh_idempotency_key_per_call
      keys = []
      stub_request(:post, @url).to_return do |request|
        keys.push(request.headers['Idempotency-Key'])
        {status: 200, headers: {'Content-Type' => 'application/json'}, body: '{}'}
      end
      @service.post_status('こんにちは')
      @service.post_status('こんばんは')

      assert_equal(2, keys.uniq.length)
    end

    # 呼び出し側が「同じ予定の投稿」を識別できるなら、プロセスをまたいでも畳める。
    def test_post_status_accepts_explicit_idempotency_key
      stub_request(:post, @url)
        .with(headers: {'Idempotency-Key' => 'morning-2026-11-01'})
        .to_return(status: 200, headers: {'Content-Type' => 'application/json'}, body: '{}')
      @service.post_status('おはよう', idempotency_key: 'morning-2026-11-01')

      assert_requested(:post, @url, times: 1)
    end

    # 🔴 モロヘイヤを経由するとき、`X-Mulukhiya` を送らないこと（#124）。
    # ⚠⚠ ヘッダを付けたほうが「経由しない」（nginx の map が Mastodon 本体へ直に
    # 流す）。⚠ 送っていることに 3 週間気付かなかったので、正テストで固定する。
    def test_post_status_omits_mulukhiya_header
      headers = nil
      stub_request(:post, @url).to_return do |request|
        headers = request.headers
        {status: 200, headers: {'Content-Type' => 'application/json'}, body: '{}'}
      end
      MastodonService.new.post_status('こんにちは')

      assert_nil(headers['X-Mulukhiya'])
    end

    # ⚠⚠ 迂回する側も見る。片方だけ通っていても気付けず、もう片方は設定次第で
    # 本番でしか踏まない（→ #30 の tomato-shrieker の 2.5 か月）。
    def test_post_status_sends_mulukhiya_header_when_disabled
      config['/mastodon/mulukhiya'] = false
      headers = nil
      stub_request(:post, @url).to_return do |request|
        headers = request.headers
        {status: 200, headers: {'Content-Type' => 'application/json'}, body: '{}'}
      end
      MastodonService.new.post_status('こんにちは')

      assert_equal(Package.full_name, headers['X-Mulukhiya'])
    end

    # ⚠⚠ トークンの検査は経路の設定に関わらず常に直（#124）。⚠ 「モロヘイヤが
    # 落ちている」が「トークンが死んでいる」に化けると、当日いちばん困る。
    def test_account_always_bypasses_mulukhiya
      url = "#{config['/mastodon/url']}/api/v1/accounts/verify_credentials"
      headers = nil
      stub_request(:get, url).to_return do |request|
        headers = request.headers
        {status: 200, headers: {'Content-Type' => 'application/json'}, body: '{}'}
      end
      MastodonService.new.account

      assert_equal(Package.full_name, headers['X-Mulukhiya'])
    end

    # ⚠⚠ 経路をログに残すこと（#124）。⚠ 経路の間違いは投稿の失敗として現れない
    # ので、成功したログの側に出ていないと気付けない。
    def test_post_status_logs_the_route
      stub_request(:post, @url)
        .to_return(status: 200, headers: {'Content-Type' => 'application/json'}, body: '{}')
      messages = []
      recorder = Object.new
      recorder.define_singleton_method(:info) {|message| messages.push(message)}
      service = MastodonService.new
      service.define_singleton_method(:logger) {recorder}
      service.post_status('こんにちは')

      assert_true(messages.first[:mulukhiya])
    end

    # ⚠ 「テストが本物のサーバーを叩かない」こと自体を見る。WebMock.enable! を忘れると
    # stub も disable_net_connect! も無言で素通りし、実サーバーへ書き込む。
    def test_net_connect_is_blocked
      assert_raise(WebMock::NetConnectNotAllowedError) do
        Net::HTTP.get(URI.parse('https://example.com/'))
      end
    end

    # 一時的な失敗は再送する（再送そのものは ginseng-core の HTTP が持つ）。
    def test_post_status_retries_server_error
      config['/http/retry/seconds'] = 0
      stub_request(:post, @url).to_return(status: 503, body: '{}')

      assert_raise(Ginseng::GatewayError) {@service.post_status('こんにちは')}
      assert_requested(:post, @url, times: config['/http/retry/limit'])
    end

    # ⚠ トークンが例外メッセージに載らないこと。ログにも出さない方針だが、
    # 例外は rescue されずに上がると別経路で出力されうる。
    def test_error_does_not_leak_token
      stub_request(:post, @url).to_return(status: 401, body: '{}')
      begin
        @service.post_status('こんにちは')
      rescue Ginseng::AuthError => e
        assert_not_include(e.message, config['/mastodon/token'])
        assert_not_include(e.backtrace.join("\n"), config['/mastodon/token'])
      end
    end

    # ログのマスクが「実際に伏せる」ことを見る正テスト。
    def test_logger_masks_token
      message = Logger.new.create_message(mastodon: 'post', token: config['/mastodon/token'])

      assert_not_include(message.keys, :token)
      assert_not_include(message.to_json, config['/mastodon/token'])
    end
  end
end
