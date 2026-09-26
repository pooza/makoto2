module Makoto
  # ⚠⚠ **`/http/timeout/seconds` が投稿・cure-api に効いていなかった**（#90 / #80 の黄 2）。
  # ⚠ **1.15.28 の `Ginseng::HTTP` が HTTParty に `timeout:` を渡すのは `upload` だけ**で、
  # `get` / `post` の実効は Net::HTTP 既定の 60 秒だった。
  #
  # ⚠⚠ **再送 3 回と合わせて 1 本の投稿が最悪 182 秒。****ライブの枠間隔 180 秒と
  # ほぼ同じ**で、tick のスレッドを占有する。
  #
  # 🔴 **塞いでいるのは上流になった**（#137・`ginseng-core` 1.19.0 / 上流 `#514`）。
  # ⚠ **`Makoto::HTTP` の上書きは外した**ので、⚠⚠ **このテストが見ているのは
  # 「上流が渡しているか」** — **追随で戻ったら、ここが落ちる。**
  class HTTPTest < TestCase
    URL = 'https://example.test/thing'.freeze

    # ⚠ **HTTParty に何が渡ったかを見る。**⚠⚠ **WebMock は Net::HTTP の層で受ける**ので、
    # そこからではタイムアウトの指定を確かめられない（**「設定に在る」だけでは、
    # 効いていなかった元の状態と区別が付かない**）。
    #
    # ⚠ 差し替えて元に戻すやり方は `test/health.rb` の `with_file_read_error` と同じ。
    def with_captured_options(method)
      captured = []
      original = HTTParty.method(method)
      HTTParty.define_singleton_method(method) do |uri, options = {}|
        captured.push(options)
        original.call(uri, options)
      end
      yield captured
    ensure
      HTTParty.define_singleton_method(method, original)
    end

    def stub_ok
      return stub_request(:any, URL).to_return(status: 200, body: '{}',
        headers: {'Content-Type' => 'application/json'})
    end

    def test_get_passes_the_configured_timeout
      stub_ok
      with_captured_options(:get) do |captured|
        HTTP.new.get(URL)

        assert_equal(config['/http/timeout/seconds'], captured.first[:timeout])
      end
    end

    def test_post_passes_the_configured_timeout
      stub_ok
      with_captured_options(:post) do |captured|
        HTTP.new.post(URL, body: {})

        assert_equal(config['/http/timeout/seconds'], captured.first[:timeout])
      end
    end

    # ⚠ **呼ぶ側が明示した値を奪わない**（`upload` は元から自分で渡している）。
    def test_explicit_timeout_wins
      stub_ok
      with_captured_options(:get) do |captured|
        HTTP.new.get(URL, timeout: 5)

        assert_equal(5, captured.first[:timeout])
      end
    end

    # ⚠ **待った秒数を見る**（本当に眠らせない）。⚠⚠ **`repeat` の `sleep` は
    # `Kernel#sleep`** なので、**そのインスタンスにだけ生やして横取りする。**
    def with_captured_sleep(http)
      slept = []
      http.define_singleton_method(:sleep) {|seconds| slept.push(seconds)}
      yield slept
    end

    # 🔴 **#100。**⚠⚠ **429 は「いつ再開してよいか」を相手が明示している唯一の
    # ステータス。**⚠ **1.15.28 は `Retry-After` を見ずに固定 1 秒で 3 連打していた** —
    # **規制されている最中に叩き直すので、規制を長引かせる方向に効く。**
    #
    # ✅ **上流（`pooza/ginseng-core#525`）が塞いだ。**⚠ **こちらは追随しただけ**なので、
    # 🔴 **戻ったときにここが落ちる**（自分の箱には規則を持たない → #137 と同じ形）。
    def test_a_429_honours_retry_after
      stub_request(:get, URL).to_return(status: 429, headers: {'Retry-After' => '2'})
      http = HTTP.new
      with_captured_sleep(http) do |slept|
        assert_raise(Ginseng::GatewayError) {http.get(URL)}

        assert_equal([2, 2], slept)
      end
    end

    # ⚠ **ヘッダが無ければ従来どおり固定値**（`/http/retry/seconds`）。
    def test_a_429_without_the_header_falls_back
      stub_request(:get, URL).to_return(status: 429)
      http = HTTP.new
      with_captured_sleep(http) do |slept|
        assert_raise(Ginseng::GatewayError) {http.get(URL)}

        assert_equal([1, 1], slept)
      end
    end

    # 🔴 **長すぎる待ちは待たない**（上流 `#525`）。⚠⚠ **プロセスを何分も止めるのは
    # 呼び出し側の期待を超える** — ⚠ **「次の機会に回す」判断は枠を持つ側のもの**
    # （→ docs/CLAUDE.md「投稿の欠落は詰めない」）。
    def test_a_long_retry_after_gives_up
      stub_request(:get, URL).to_return(status: 429, headers: {'Retry-After' => '3600'})
      http = HTTP.new
      with_captured_sleep(http) do |slept|
        assert_raise(Ginseng::GatewayError) {http.get(URL)}

        assert_equal([], slept)
      end
    end

    # 🔴 **Mastodon は 429 に `Retry-After` を付けず、`X-RateLimit-Reset`（ISO 8601）だけを返す**
    # （#425）。✅ **上流（`pooza/ginseng-core#657`・v1.25.1）がそれを読む**ようになったので追随した
    # （#438）。⚠ **こちらは追随しただけ**なので、🔴 **戻ったときにここが落ちる。**
    def test_a_429_honours_the_ratelimit_reset
      reset = (Time.now + 3).utc.iso8601
      stub_request(:get, URL).to_return(status: 429, headers: {'X-RateLimit-Reset' => reset})
      http = HTTP.new
      with_captured_sleep(http) do |slept|
        assert_raise(Ginseng::GatewayError) {http.get(URL)}

        assert_equal(2, slept.size)
        slept.each {|seconds| assert_includes(1..3, seconds)}
      end
    end

    # 🔴 **投稿数の制限（300 本 / 3 時間）の窓は待たずに 1 回で諦める**（#438）。⚠⚠ **追随する前は
    # 1 秒おきに計 3 回叩いていた**（→ docs/CLAUDE.md の #100 の記述）。
    def test_a_long_ratelimit_reset_gives_up
      reset = (Time.now + (3 * 3600)).utc.iso8601
      stub_request(:get, URL).to_return(status: 429, headers: {'X-RateLimit-Reset' => reset})
      http = HTTP.new
      with_captured_sleep(http) do |slept|
        assert_raise(Ginseng::GatewayError) {http.get(URL)}

        assert_equal([], slept)
      end
    end

    # 設定した予算（タイムアウト × 再送 ＋ 待ち）が、ライブの枠間隔より短いこと。
    #
    # ⚠⚠ **これは wall-clock の上限ではない**（2026-08-16・#91 のレビュー指摘・#92）。
    # ⚠ **HTTParty の `timeout` は Net::HTTP の 1 回の socket 操作ごとに効く**ので、
    # ⚠⚠ **チャンクを 30 秒未満の間隔で送り続ける相手は、この予算を超えて掴んでいられる。**
    # **ここが見ているのは「設定の値どうしが噛み合っているか」まで。**
    def test_configured_budget_stays_inside_a_live_slot
      worst = config['/http/timeout/seconds'] * config['/http/retry/limit']
      worst += config['/http/retry/seconds'] * (config['/http/retry/limit'] - 1)
      interval = Fugit::Duration.parse(config['/live/timetable/interval']).to_sec

      assert_operator(worst, :<, interval)
    end

    # 🔴 **json 3 の下で HTTParty と ActiveSupport が JSON を読めること**（#426）。
    #
    # ⚠⚠ **json 3.x は未知のキーワードを `ArgumentError` にする** — **HTTParty の `parser.rb` は
    # `JSON.parse(body, quirks_mode: true, allow_nan: true)`、`ActiveSupport::JSON.decode` は
    # 位置引数の Hash を渡す**ので、素の json 3 ではどちらも落ちる（実測）。
    # ⚠ **通っているのは `ginseng-core` の `ginseng.rb` が `require 'yajl/json_gem'` で
    # `JSON.parse` を差し替えているから。**🔴 **上流が yajl を外した日に、ここが赤くなる**
    # （**外れると Mastodon・cure-api・iTunes の `parsed_response` が全部 `ArgumentError`**）。
    def test_json_is_parsed_through_the_yajl_override
      assert_equal({'id' => '1'}, HTTParty::Parser.call('{"id":"1"}', :json))
      assert_equal({'id' => '1'}, ActiveSupport::JSON.decode('{"id":"1"}'))
    end
  end
end
