module Makoto
  # 取りこぼしたメンションに追いつく（#610）。
  class MentionCatchUpTest < TestCase
    NOW = Time.utc(2026, 11, 10, 3, 0, 0)

    class FakeService
      attr_reader :calls

      def initialize(notifications)
        @notifications = notifications
        @calls = []
      end

      def mentions_since(min_id, limit:)
        @calls.push([min_id, limit])
        raise Ginseng::GatewayError, 'mastodon returned 502' if @notifications == :fail
        return @notifications
      end
    end

    setup do
      FileUtils.rm_f(Heartbeat.path)
    end

    teardown do
      FileUtils.rm_f(Heartbeat.path)
    end

    def mention(id, minutes_ago)
      return {'id' => id, 'type' => 'mention', 'created_at' => (NOW - (minutes_ago * 60)).iso8601}
    end

    def catch_up(notifications)
      @queued = []
      @service = FakeService.new(notifications)
      return MentionCatchUp.new(
        handler: ->(notification, received_at) {@queued.push([notification['id'], received_at])},
        service: @service,
        clock: -> {NOW},
      )
    end

    # ⚠ 一度も処理していなければ何もしない（初回）。
    def test_nothing_without_a_starting_point
      assert_nil(catch_up([mention('11', 1)]).call)
      assert_empty(@service.calls)
    end

    # 🔴 **最後に処理した ID から引いて積む。受けた時刻は投稿の時刻。**
    def test_queues_what_was_missed
      Heartbeat.record_notification_id('10')

      assert_equal(2, catch_up([mention('11', 3), mention('12', 1)]).call)
      assert_equal([['10', MentionCatchUp::LIMIT]], @service.calls)
      assert_equal([['11', NOW - 180], ['12', NOW - 60]], @queued)
    end

    # 🔴 **15 分を超えたものには返さない**。
    def test_stale_mentions_are_dropped
      Heartbeat.record_notification_id('10')

      assert_equal(1, catch_up([mention('11', 16), mention('12', 14)]).call)
      assert_equal(['12'], @queued.map(&:first))
    end

    # ⚠ 引けなくても例外を上げない（受信を止めない）。
    def test_a_failure_does_not_raise
      Heartbeat.record_notification_id('10')

      assert_nil(catch_up(:fail).call)
      assert_empty(@queued)
    end

    # ⚠ ID は大きくなるときだけ書く（追いついた古い通知で戻さない）。
    def test_the_notification_id_only_grows
      Heartbeat.record_notification_id('12')
      Heartbeat.record_notification_id('9')

      assert_equal('12', Heartbeat.notification_id)
      Heartbeat.record_notification_id('100')

      assert_equal('100', Heartbeat.notification_id)
      Heartbeat.record_notification_id('n1')

      assert_equal('100', Heartbeat.notification_id)
    end
  end
end
