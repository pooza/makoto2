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
        handler: ->(notification, received_at) {@queued.push([notification['id'], received_at]) && true},
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

      assert_false(catch_up(:fail).call)
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

    # 🔴 **引けなかったら、引けるまで起点を止める**（PR #633 の Codex の P2）。
    def test_a_failure_holds_the_checkpoint
      Heartbeat.record_notification_id('10')

      assert_false(catch_up(:fail).call)
      Heartbeat.checkpoint_notification('20')

      assert_equal('10', Heartbeat.notification_id)
      assert_equal(1, catch_up([mention('11', 1)]).call)
      Heartbeat.checkpoint_notification('20')

      assert_equal('20', Heartbeat.notification_id)
    end

    # 🔴 **起点を止めている間に処理し終えたものは除く**（#635）。
    def test_handled_notifications_are_skipped
      Heartbeat.record_notification_id('10')
      Heartbeat.hold_notification_id(now: NOW)
      Heartbeat.checkpoint_notification('12')

      assert_equal(1, catch_up([mention('11', 1), mention('12', 1)]).call)
      assert_equal(['11'], @queued.map(&:first))
    end

    # 🔴 **積めなかった分は数えない・引くのは待ち行列の半分まで**（#637）。
    def test_dropped_notifications_are_not_counted
      Heartbeat.record_notification_id('10')
      @service = FakeService.new([mention('11', 1), mention('12', 1)])
      subject = MentionCatchUp.new(handler: ->(n, _) {n['id'] == '11'}, service: @service, clock: -> {NOW})

      assert_equal(1, subject.call)
      assert_equal([['10', ChatResponder::QUEUE_MAX / 2]], @service.calls)
    end

    # 🔴 **積んだ分を処理し終えるまで、起点はそれを越えない**（#637・PR #643 の Codex の P2）。
    # 起点 10・ライブの 20 が先・追いついた 11 / 12 が後ろ → 20 を処理しても起点は 10 のまま。
    def test_the_checkpoint_does_not_pass_pending_notifications
      Heartbeat.record_notification_id('10')
      Heartbeat.checkpoint_notification('20', pending: ['11', '12'])

      assert_equal('10', Heartbeat.notification_id)
      assert_true(Heartbeat.handled_notification?('20'))

      Heartbeat.checkpoint_notification('11', pending: ['12'])

      assert_equal('11', Heartbeat.notification_id)

      Heartbeat.checkpoint_notification('12', pending: [])

      assert_equal('20', Heartbeat.notification_id)
      assert_false(Heartbeat.handled_notification?('20'))
    end
  end
end
