module Makoto
  class ChatMemoryTest < TestCase
    class FakeService
      attr_reader :calls

      def initialize(statuses = [], error: nil)
        @statuses = statuses
        @error = error
        @calls = 0
      end

      def own_statuses(**)
        @calls += 1
        raise @error if @error
        return @statuses
      end
    end

    NOW = Time.new(2026, 11, 15, 8, 40, 0, '+09:00')

    setup do
      # ⚠ ニュースは test/chat_news.rb で見る。ここでは Mastodon を引かない。
      config['/chat/news/enabled'] = false
    end

    teardown do
      Heartbeat.clear_chat_memory_unavailable
    end

    def status(text, hours_ago:, visibility: 'public')
      return {
        'created_at' => (NOW - (hours_ago * 3600)).utc.iso8601,
        'visibility' => visibility,
        'content' => "<p>#{text}</p>",
      }
    end

    # 🔴 **いまの日時は曜日つきで渡す**（#652 — 実況の振りに、いつの何の実況かを分からせる）。
    def test_now_has_the_weekday
      prompt = ChatMemory.new(service: FakeService.new).to_prompt(NOW)

      assert_include(prompt, '2026-11-15（日）08:40')
      assert_not_include(prompt, '最近の自分の投稿')
    end

    def test_recent_posts_are_newest_first_and_capped
      config['/chat/memory/max_posts'] = 2
      statuses = [status('3 本目', hours_ago: 1), status('2 本目', hours_ago: 2), status('1 本目', hours_ago: 3)]
      prompt = ChatMemory.new(service: FakeService.new(statuses)).to_prompt(NOW)

      assert_include(prompt, '3 本目')
      assert_include(prompt, '2 本目')
      assert_not_include(prompt, '1 本目')
      assert_operator(prompt.index('3 本目'), :<, prompt.index('2 本目'))
    end

    def test_long_posts_are_cut
      prompt = ChatMemory.new(service: FakeService.new([status('あ' * 300, hours_ago: 1)])).to_prompt(NOW)

      assert_include(prompt, "#{'あ' * ChatMemory::POST_MAX_LENGTH}…")
    end

    # ⚠ **引いたものは覚えておく**（メンションのたびに Mastodon を引かない）。
    def test_statuses_are_cached
      service = FakeService.new([status('朝の挨拶', hours_ago: 1)])
      memory = ChatMemory.new(service:)
      memory.to_prompt(NOW)
      memory.to_prompt(NOW + 30)

      assert_equal(1, service.calls)
      memory.to_prompt(NOW + 600)

      assert_equal(2, service.calls)
    end

    # 🔴 **引けなくても止めない**（「いま」だけを渡す）。
    def test_a_failure_leaves_only_now
      service = FakeService.new(error: Ginseng::GatewayError.new('down'))
      prompt = ChatMemory.new(service:).to_prompt(NOW)

      assert_include(prompt, '## いま')
      assert_not_include(prompt, '最近の自分の投稿')
    end

    # 🔴 **`GatewayError` でない失敗（400 / 404 など）でも止めない**（1.1 のリリース前レビュー）。
    def test_a_not_found_also_leaves_only_now
      service = FakeService.new(error: Ginseng::NotFoundError.new('gone'))
      prompt = ChatMemory.new(service:).to_prompt(NOW)

      assert_include(prompt, '## いま')
      assert_not_include(prompt, '最近の自分の投稿')
    end

    # 🔴 **引けなかったら、しばらく引きに行かない**（#680 の B1）。⚠ 前に引けたものがあればそれを使う。
    def test_a_failure_backs_off
      service = FakeService.new([status('朝の挨拶', hours_ago: 1)])
      memory = ChatMemory.new(service:)
      memory.to_prompt(NOW)
      service.instance_variable_set(:@error, Ginseng::GatewayError.new('down'))
      memory.to_prompt(NOW + 120)

      assert_equal(2, service.calls)
      assert_include(memory.to_prompt(NOW + 150), '朝の挨拶')
      assert_equal(2, service.calls)
      memory.to_prompt(NOW + 200)

      assert_equal(3, service.calls)
    end

    # 🔴 **引けない状態を痕跡に残し、引けたら消す**（#680 の B4 → `makoto status`）。
    def test_a_failure_is_recorded_until_it_recovers
      service = FakeService.new(error: Ginseng::GatewayError.new('down'))
      memory = ChatMemory.new(service:)
      memory.to_prompt(NOW)

      assert_not_nil(Heartbeat.chat_memory_unavailable_since)
      service.instance_variable_set(:@error, nil)
      memory.to_prompt(NOW + 120)

      assert_nil(Heartbeat.chat_memory_unavailable_since)
    end

    # ⚠ 外の口は短く待ち、リトライしない（#680 の B1）。
    def test_the_default_service_waits_briefly
      http = ChatMemory.new.send(:service).http

      assert_equal(config['/chat/lookup/timeout'], http.timeout)
      assert_equal(0, http.retry_limit)
    end
  end
end
