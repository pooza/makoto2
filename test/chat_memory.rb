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

    def status(text, hours_ago:, visibility: 'public')
      return {'created_at' => (NOW - (hours_ago * 3600)).utc.iso8601, 'visibility' => visibility,
              'content' => "<p>#{text}</p>"}
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
      memory.to_prompt(NOW + 60)

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
  end
end
