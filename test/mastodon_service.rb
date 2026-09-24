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

    # 🔴 **リダイレクトを追わない**（#282）。⚠⚠ **追うと POST が GET に化け、資格情報を含む
    # ヘッダが別ホストへ送られる。**⚠ **3xx は「status ではない」として落ちる。**
    #
    # 🔴 **当てにしているのは上流の振る舞い**（`ginseng-fediverse` v2.0.1 以降・#349 で
    # 暫定の上書きを畳んだ）。⚠⚠ **こちらに `post` は無いので、このテストが守るのは
    # 「引いている gem がこの性質を持ち続けること」** — ⚠ **上流が `post` を組み替えて
    # `follow_redirects` を落とせば、黙ってトークンが漏れるのではなく、ここが赤くなる**
    # （#280 で採ったのと同じ置き方）。
    def test_post_status_does_not_follow_a_redirect
      elsewhere = 'https://elsewhere.example/api/v1/statuses'
      stub_request(:post, @url).to_return(status: 302, headers: {'Location' => elsewhere})
      stub_request(:any, elsewhere)

      assert_raise(Ginseng::GatewayError) {@service.post_status('こんにちは')}
      assert_requested(:post, @url, times: 1)
      assert_not_requested(:any, elsewhere)
    end

    def test_post_status_sends_token
      stub_request(:post, @url)
        .with(headers: {'Authorization' => "Bearer #{config['/mastodon/token']}"})
        .to_return(status: 200, headers: {'Content-Type' => 'application/json'}, body: status_body)
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
        {status: 200, headers: {'Content-Type' => 'application/json'}, body: status_body}
      end
      @service.post_status('こんにちは')
      @service.post_status('こんばんは')

      assert_equal(2, keys.uniq.length)
    end

    # 呼び出し側が「同じ予定の投稿」を識別できるなら、プロセスをまたいでも畳める。
    def test_post_status_accepts_explicit_idempotency_key
      stub_request(:post, @url)
        .with(headers: {'Idempotency-Key' => 'morning-2026-11-01'})
        .to_return(status: 200, headers: {'Content-Type' => 'application/json'}, body: status_body)
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
        {status: 200, headers: {'Content-Type' => 'application/json'}, body: status_body}
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
        {status: 200, headers: {'Content-Type' => 'application/json'}, body: status_body}
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
        {status: 200, headers: {'Content-Type' => 'application/json'}, body: status_body}
      end
      MastodonService.new.account

      assert_equal(Package.full_name, headers['X-Mulukhiya'])
    end

    # 🔴 **別ホストへのリダイレクトでトークンを渡さない**（#349）。⚠⚠ **HTTParty が守るのは
    # `basic_auth` / `digest_auth` だけ**なので、`headers` に置いた `Authorization` は
    # 素のままだとホストが変わっても付いていく。
    def test_account_rejects_a_redirect_to_another_host
      url = "#{config['/mastodon/url']}/api/v1/accounts/verify_credentials"
      elsewhere = 'https://elsewhere.example/api/v1/accounts/verify_credentials'
      stub_request(:get, url).to_return(status: 302, headers: {'Location' => elsewhere})
      stub_request(:any, elsewhere)

      assert_raise(Ginseng::GatewayError) {MastodonService.new.account}
      assert_requested(:get, url, times: 1)
      assert_not_requested(:any, elsewhere)
    end

    # ⚠ **同じホストのリダイレクトは追える**（#349）。⚠⚠ **一律に `follow_redirects: false`
    # にしないのはこのため** — **証明書切替やパスの整理で自分のホストが 301 を返す形は、
    # トークンの漏れ方ではない。**
    def test_account_follows_a_redirect_within_the_same_host
      url = "#{config['/mastodon/url']}/api/v1/accounts/verify_credentials"
      moved = "#{config['/mastodon/url']}/api/v2/accounts/verify_credentials"
      stub_request(:get, url).to_return(status: 301, headers: {'Location' => moved})
      stub_request(:get, moved)
        .with(headers: {'Authorization' => "Bearer #{config['/mastodon/token']}"})
        .to_return(status: 200, headers: {'Content-Type' => 'application/json'},
          body: {acct: 'test', statuses_count: 1}.to_json)

      assert_equal('test', MastodonService.new.account['acct'])
      assert_requested(:get, moved, times: 1)
    end

    # ⚠⚠ 経路をログに残すこと（#124）。⚠ 経路の間違いは投稿の失敗として現れない
    # ので、成功したログの側に出ていないと気付けない。
    def test_post_status_logs_the_route
      stub_request(:post, @url)
        .to_return(status: 200, headers: {'Content-Type' => 'application/json'}, body: status_body)
      messages = []
      recorder = Object.new
      recorder.define_singleton_method(:info) {|message| messages.push(message)}
      service = MastodonService.new
      service.define_singleton_method(:logger) {recorder}
      service.post_status('こんにちは')

      assert_true(messages.first[:mulukhiya])
    end

    # 🔴 **投稿先と同じ数え方の長さも出す**（#351）。
    def test_post_status_logs_the_post_length
      stub_request(:post, @url)
        .to_return(status: 200, headers: {'Content-Type' => 'application/json'}, body: status_body)
      messages = []
      recorder = Object.new
      recorder.define_singleton_method(:info) {|message| messages.push(message)}
      service = MastodonService.new
      service.define_singleton_method(:logger) {recorder}
      service.post_status("あ https://example.com/#{'x' * 40}")

      assert_equal(2 + 23, messages.first[:post_length])
    end

    # 🔴 **モロヘイヤが足した分を毎回残す**（#351）。
    #
    # ⚠⚠ **応答の `content` が「足された後の本文」**なので、**読み取り権は要らない** —
    # ⚠ **`/api/v1/statuses/:id/source` は `read` が要るが、投稿の応答は `write` で返る。**
    def test_post_status_logs_what_the_proxy_added
      tag = '<p><a href="https://st2.precure.ml/tags/precure_fun" class="mention hashtag"' \
        ' rel="tag">#<span>precure_fun</span></a></p>'
      stub_request(:post, @url).to_return(
        status: 200, headers: {'Content-Type' => 'application/json'},
        body: status_body(content: "<p>こんにちは</p>#{tag}")
      )
      messages = []
      recorder = Object.new
      recorder.define_singleton_method(:info) {|message| messages.push(message)}
      service = MastodonService.new
      service.define_singleton_method(:logger) {recorder}
      service.post_status('こんにちは')

      # ⚠ 空行 2 字 ＋ `#precure_fun` 12 字
      assert_equal(14, messages.first[:proxy_added])
    end

    # 🔴 **リモートのメンションはドメインを戻す**（#351・Codex の P2）。
    #
    # ⚠⚠ **Mastodon は `@alice@remote.example` を「見える文字は `@alice` だけ」で返す**ので、
    # ⚠ **戻さないとドメインぶん（15 字）短く出て、足された分が負にもなりうる。**
    def test_post_status_restores_the_domain_of_a_remote_mention
      card = '<span class="h-card"><a href="https://remote.example/@alice"' \
        ' class="u-url mention">@<span>alice</span></a></span>'
      tag = '<p><a href="https://st2.precure.ml/tags/precure_fun" class="mention hashtag"' \
        ' rel="tag">#<span>precure_fun</span></a></p>'
      stub_request(:post, @url).to_return(
        status: 200, headers: {'Content-Type' => 'application/json'},
        body: status_body(
          content: "<p>#{card} おはよう</p>#{tag}",
          mentions: [{acct: 'alice@remote.example', username: 'alice'}],
        )
      )
      messages = []
      recorder = log_recorder(messages)
      service = MastodonService.new
      service.define_singleton_method(:logger) {recorder}
      service.post_status('@alice@remote.example おはよう')

      # ⚠ 空行 2 字 ＋ `#precure_fun` 12 字（🔴 **メンションのぶんは差に出ない**）
      assert_equal(14, messages.first[:proxy_added])
    end

    # 🔴🔴 **負の値は記録しない**（#351）。⚠⚠ **モロヘイヤが字数を減らすことは無い**ので、
    # **負なら応答から本文を戻しきれていない** — ⚠ **黙って混ぜると分布ごと信用できなくなる。**
    def test_post_status_refuses_a_negative_proxy_added
      stub_request(:post, @url).to_return(
        status: 200, headers: {'Content-Type' => 'application/json'},
        body: status_body(content: '<p>こん</p>')
      )
      messages = []
      recorder = log_recorder(messages)
      service = MastodonService.new
      service.define_singleton_method(:logger) {recorder}
      service.post_status('こんにちは')

      assert_equal(['proxy_added is negative'], messages.filter_map {|m| m[:message]})
      assert_nil(messages.find {|m| m[:status_id]}[:proxy_added])
      # 🔴 **診断の行に `proxy_added` を出さない**（Codex の P2）— ⚠⚠ **出すと
      # `RehearsalReport#count_post` が拾い、捨てた負の値が分布へ入る。**
      warned = messages.find {|m| m[:message]}

      assert_false(warned.key?(:proxy_added))
      assert_equal(-3, warned[:rejected_length])
    end

    # ⚠ **迂回しているときは測らない**（🔴 **モロヘイヤが何もしていない**）。
    def test_post_status_does_not_measure_the_proxy_when_bypassing
      stub_request(:post, @url).to_return(
        status: 200, headers: {'Content-Type' => 'application/json'},
        body: status_body(content: '<p>こんにちは</p>')
      )
      messages = []
      recorder = Object.new
      recorder.define_singleton_method(:info) {|message| messages.push(message)}
      service = MastodonService.new
      service.mulukhiya_enable = false
      service.define_singleton_method(:logger) {recorder}
      service.post_status('こんにちは')

      assert_nil(messages.first[:proxy_added])
    end

    # 🔴 **記録の都合で「成功した投稿が失敗した」に化けさせない**（fail-open・#351）。
    # ⚠⚠ **`content` を持たない 200 でも `post_status` は通る。**
    def test_post_status_survives_a_response_without_content
      stub_request(:post, @url)
        .to_return(status: 200, headers: {'Content-Type' => 'application/json'}, body: status_body)
      status = @service.post_status('こんにちは')

      assert_equal('114514', status['id'])
    end

    def stub_instance(status, body)
      url = "#{config['/mastodon/url']}/api/v1/instance"
      headers = {'Content-Type' => 'application/json'}
      return stub_request(:get, url).to_return(status: status, body: body.to_json, headers: headers)
    end

    # 🔴 **投稿先が申告する上限を読む**（#351）。⚠ **トークンは付けず、直で聞く。**
    def test_declared_max_length
      headers = nil
      stub_request(:get, "#{config['/mastodon/url']}/api/v1/instance").to_return do |request|
        headers = request.headers
        {status: 200, headers: {'Content-Type' => 'application/json'},
         body: {configuration: {statuses: {max_characters: 3000}}}.to_json}
      end

      assert_equal(3000, MastodonService.new.declared_max_length)
      assert_equal(Package.full_name, headers['X-Mulukhiya'])
      assert_false(headers.key?('Authorization'))
    end

    # ⚠ **書かれていなければ nil**（既定値に倒さない）。
    def test_declared_max_length_without_the_field
      stub_instance(200, {})

      assert_nil(MastodonService.new.declared_max_length)
    end

    # ⚠⚠ **聞けなければ例外**（上流の `max_post_text_length` のように 500 に倒れない）。
    def test_declared_max_length_raises_when_unreachable
      config['/http/retry/seconds'] = 0
      stub_instance(503, {})

      assert_raise(Ginseng::GatewayError) {MastodonService.new.declared_max_length}
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

    # 🔴 **200 で HTML が返ったら失敗として上げること**（#272）。
    #
    # ⚠⚠ **httparty は対応していない Content-Type ではボディを String のまま返す。**
    # ⚠ **`response['id']` は `String#[]('id')` になり、HTML に `id` の 2 文字があれば
    # `"id"` を返す** — 🔴 **例外にならないので、`PostingJob` は成功として数え、
    # `Heartbeat` の連敗を打ち消し、履歴まで進める**（投稿は 1 通も出ていないのに）。
    def test_post_status_rejects_html_body
      stub_request(:post, @url).to_return(
        status: 200,
        headers: {'Content-Type' => 'text/html'},
        # ⚠ **`id` の 2 文字を含む HTML**（`<meta name=... id=...>` でまず含まれる）。
        # ⚠⚠ **これを弾かないと `status_id` に `"id"` という 2 文字が載る。**
        body: '<html><body id="maintenance">ただいまメンテナンス中です</body></html>',
      )

      assert_raise(Ginseng::GatewayError) {@service.post_status('こんにちは')}
      # ⚠ **再送しない。**🔴 **200 が返っている以上 `HTTP#retryable?` は発火しない**ので、
      # ⚠⚠ **1 回だけ叩いて諦めるのが正しい**（→ `PostingJob#post` のコメント）。
      assert_requested(:post, @url, times: 1)
    end

    # ⚠⚠ **JSON でも status でなければ弾くこと**（#272）。
    # 🔴 **`Hash` かどうかだけでは、200 で `{"status":"maintenance"}` を返す前段を通す。**
    def test_post_status_rejects_json_without_id
      stub_request(:post, @url).to_return(
        status: 200,
        headers: {'Content-Type' => 'application/json'},
        body: {status: 'maintenance'}.to_json,
      )

      assert_raise(Ginseng::GatewayError) {@service.post_status('こんにちは')}
    end

    # ⚠ **弾いたことがログに残ること**（#272）。🔴 **型と経路を出す** — ⚠⚠ **誤ルーティング
    # はモロヘイヤの側で起きる**ので、**経路が分からないと切り分けに 1 往復増える**（#124）。
    def test_post_status_logs_the_unexpected_shape
      stub_request(:post, @url)
        .to_return(status: 200, headers: {'Content-Type' => 'text/html'}, body: '<html></html>')
      messages = []
      recorder = Object.new
      recorder.define_singleton_method(:warn) {|message| messages.push(message)}
      service = MastodonService.new
      service.define_singleton_method(:logger) {recorder}
      begin
        service.post_status('こんにちは')
      rescue Ginseng::GatewayError
        nil
      end

      assert_equal(1, messages.length)
      assert_equal('String', messages.first[:type])
      assert_true(messages.first[:mulukhiya])
    end

    # ⚠⚠ **本文をログに載せないこと**（#272）。🔴 **HTML が丸ごとログに出ると、
    # 前段が返したものを全部 syslog へ書くことになる** — ⚠ **型だけで区別は足りる。**
    def test_post_status_does_not_log_the_unexpected_body
      body = '<html><body>ただいまメンテナンス中です</body></html>'
      stub_request(:post, @url)
        .to_return(status: 200, headers: {'Content-Type' => 'text/html'}, body: body)
      messages = []
      recorder = Object.new
      recorder.define_singleton_method(:warn) {|message| messages.push(message)}
      service = MastodonService.new
      service.define_singleton_method(:logger) {recorder}
      begin
        service.post_status('こんにちは')
      rescue Ginseng::GatewayError
        nil
      end

      assert_not_include(messages.first.to_json, 'メンテナンス')
    end

    # 🔴 **分類が化けないこと**（#272）。⚠⚠ **`GatewayError#source_status` は `message` の
    # 末尾 3 桁を上流のステータスとして読む**ので、⚠ **例外メッセージの末尾に数字を
    # 置くと `classify` が `PERMANENT_STATUSES` に当ててしまう**（400 なら `RequestError`）。
    def test_post_status_unexpected_shape_is_not_classified_as_permanent
      stub_request(:post, @url)
        .to_return(status: 200, headers: {'Content-Type' => 'text/html'}, body: '<html></html>')
      error = nil
      begin
        @service.post_status('こんにちは')
      rescue Ginseng::GatewayError => e
        error = e
      end

      assert_instance_of(Ginseng::GatewayError, error)
      assert_equal(502, error.source_status)
    end

    # 🔴 **本文が読めないときも失敗として上げること**（#272・Codex の P2）。
    #
    # ⚠⚠ **`Content-Type` が `application/json` なら httparty は `JSON.parse` を通す**
    # ので、**素のテキストは `JSON::ParserError`**（実測）。⚠ **`post_status` は
    # `Ginseng::GatewayError` しか rescue しない**ので、🔴 **分類も警告も通らずに
    # 外へ出ていた** — ⚠⚠ **`bin/makoto post` の rescue も素通りする。**
    def test_post_status_rejects_a_body_that_cannot_be_parsed
      stub_request(:post, @url).to_return(
        status: 200,
        headers: {'Content-Type' => 'application/json'},
        body: 'ただいまメンテナンス中です',
      )

      assert_raise(Ginseng::GatewayError) {@service.post_status('こんにちは')}
    end

    # ⚠ **何で落ちたのかがログに残ること**（#272）。🔴 **`String` ではなく
    # `JSON::ParserError` と出る** — ⚠⚠ **「200 で HTML」と「200 で壊れた JSON」は
    # 切り分け先が違う**（前者は vhost、後者は前段が本文を切っている）。
    def test_post_status_logs_the_parse_failure
      stub_request(:post, @url).to_return(
        status: 200,
        headers: {'Content-Type' => 'application/json'},
        body: 'ただいまメンテナンス中です',
      )
      messages = []
      recorder = Object.new
      recorder.define_singleton_method(:warn) {|message| messages.push(message)}
      service = MastodonService.new
      service.define_singleton_method(:logger) {recorder}
      begin
        service.post_status('こんにちは')
      rescue Ginseng::GatewayError
        nil
      end

      assert_equal(['JSON::ParserError'], messages.map {|message| message[:type]})
      assert_not_include(messages.first.to_json, 'メンテナンス')
    end

    private

    # ⚠ **Mastodon が実際に返す形**（`POST /api/v1/statuses` は必ず `id` を持つ Status）。
    # 🔴 **`'{}'` で書かない** — ⚠⚠ **起こりえない応答を前提にしたテストは、
    # 応答の形を検査し始めた日に「壊れた」ように見える**（#272 で実際にそうなった）。
    # @param content [String, nil] ⚠ **応答の本文（HTML）** — 🔴 **モロヘイヤが足した後の形**
    # @param mentions [Array, nil] ⚠ **メンションの一覧**（🔴 **リモートはここからドメインを戻す**）
    def status_body(content: nil, mentions: nil)
      body = {
        id: '114514',
        url: "#{config['/mastodon/url']}/@test/114514",
        visibility: 'public',
      }
      body[:content] = content if content
      body[:mentions] = mentions if mentions
      return body.to_json
    end

    # ⚠ **`info` と `warn` の両方を受ける**（🔴 **`proxy_added` は落ちたら `warn` を出す**）。
    def log_recorder(messages)
      recorder = Object.new
      recorder.define_singleton_method(:info) {|message| messages.push(message)}
      recorder.define_singleton_method(:warn) {|message| messages.push(message)}
      return recorder
    end
  end
end
