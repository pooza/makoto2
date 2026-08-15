module Makoto
  # ⚠⚠ **`/http/timeout/seconds` が投稿・cure-api に効いていなかった**（#90 / #80 の黄 2）。
  # ⚠ **`Ginseng::HTTP` が HTTParty に `timeout:` を渡すのは `upload` だけ**で、
  # `get` / `post` の実効は Net::HTTP 既定の 60 秒だった。
  #
  # ⚠⚠ **再送 3 回と合わせて 1 本の投稿が最悪 182 秒。****ライブの枠間隔 180 秒と
  # ほぼ同じ**で、tick のスレッドを占有する。
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

    # ⚠⚠ **1 本の投稿が枠を跨がないこと。**⚠ **再送を含めた最悪の滞留が、いちばん
    # 短いライブの枠間隔（180 秒）より短いこと**を、設定の値だけで確かめる。
    def test_worst_case_stays_inside_a_live_slot
      worst = config['/http/timeout/seconds'] * config['/http/retry/limit']
      worst += config['/http/retry/seconds'] * (config['/http/retry/limit'] - 1)
      interval = Fugit::Duration.parse(config['/live/timetable/interval']).to_sec

      assert_operator(worst, :<, interval)
    end
  end
end
