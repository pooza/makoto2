module Makoto
  class FollowSyncTest < TestCase
    # Mastodon の代わり。フォローした・外した ID を覚える。
    class FakeService
      attr_accessor :following, :locked, :refused
      attr_reader :followed, :unfollowed

      def initialize(following: [])
        @following = following
        @locked = []
        @refused = []
        @followed = []
        @unfollowed = []
      end

      def following_ids
        raise Ginseng::GatewayError, 'mastodon: following unavailable' if @following.nil?
        return @following
      end

      def follow(id)
        raise Ginseng::AuthError, 'mastodon returned 403' if @refused.include?(id.to_s)
        @followed.push(id.to_s)
        locked = @locked.include?(id.to_s)
        return {'id' => id.to_s, 'following' => !locked, 'requested' => locked}
      end

      def unfollow(id)
        @unfollowed.push(id.to_s)
        return {'id' => id.to_s, 'following' => false}
      end
    end

    # ⚠ 承認待ちは痕跡に残る（PR #632 の Codex の P2）ので、テストごとに消す。
    teardown do
      FileUtils.rm_f(Heartbeat.path)
    end

    def setup
      FileUtils.rm_f(Heartbeat.path)
      @repository = ChatRepository.new(empty_db)
      @followers = ['1', '2', '3']
      @service = FakeService.new
      @roster = FollowerRoster.new(fetcher: -> {@followers.nil? ? raise(Ginseng::GatewayError, 'down') : @followers})
    end

    # ⚠ `quiet_chat`（コールバック）は `setup` メソッドの後に走って切るので、ここで入れ直す。
    def follow_back!
      config['/chat/follow/enabled'] = true
    end

    def subject
      @subject ||= FollowSync.new(service: @service, roster: @roster, repository: @repository)
      return @subject
    end

    def test_follow_back_on_notification
      follow_back!

      assert_equal(:follow, subject.on_follow({'id' => '9', 'acct' => 'fan'}))
      assert_equal(['9'], @service.followed)
    end

    # ⚠ ボットも返す（突き合わせと同じ扱いにする・PR #608 の Codex の P2）。
    def test_bots_are_followed_back
      follow_back!
      subject.on_follow({'id' => '9', 'acct' => 'bot', 'bot' => true})

      assert_equal(['9'], @service.followed)
    end

    # ⚠ **対象でなくなった相手への承認待ちは取り消す**（PR #608 の Codex の P2）。
    def test_sync_cancels_pending_requests_of_former_followers
      @service.locked = ['3']
      @service.following = ['1', '2']

      assert_equal(['3'], subject.sync[:followed])
      @followers = ['1', '2']

      assert_equal(['3'], subject.sync[:unfollowed])
      assert_equal(['3'], @service.unfollowed)
    end

    # 🔴 **承認待ちは痕跡に残り、別のインスタンス（再起動・CLI）からも取り消せる**（PR #632 の Codex の P2）。
    def test_pending_requests_survive_another_instance
      @service.locked = ['3']
      @service.following = ['1', '2']
      subject.sync

      assert_equal(['3'], Heartbeat.follow_requested)
      @followers = ['1', '2']
      another = FollowSync.new(service: @service, roster: @roster, repository: @repository)

      assert_equal(['3'], another.preview[1].to_a)
      assert_equal(['3'], another.sync(force: true)[:unfollowed])
      assert_empty(Heartbeat.follow_requested)
    end

    # ⚠ **返さない設定でも、一覧には足す**（#510 の門）。
    def test_a_follow_is_added_to_the_roster_even_when_disabled
      config['/chat/follow/enabled'] = false
      @roster.refresh
      subject.on_follow({'id' => '9', 'acct' => 'fan'})

      assert_true(@roster.include?('9'))
      assert_empty(@service.followed)
    end

    # 🔴 **返事を止めた相手・ペナルティ中の相手には返さない**（2026-11-09・オーナー）。
    def test_stopped_accounts_are_not_followed_back
      follow_back!
      @repository.block('9', 'blocked')
      @repository.save_penalty('8', {acct: 'penalized', marks: 1, until_at: Time.now + 3600, marked_at: Time.now,
        reason: 'provoke'})
      subject.on_follow({'id' => '9', 'acct' => 'blocked'})
      subject.on_follow({'id' => '8', 'acct' => 'penalized'})

      assert_empty(@service.followed)
    end

    def test_sync_follows_missing_and_unfollows_former_followers
      @service.following = ['1', '4']
      result = subject.sync

      assert_equal(['2', '3'], result[:followed].sort)
      assert_equal(['4'], result[:unfollowed])
      assert_equal(['4'], @service.unfollowed)
    end

    # ⚠ 止めた相手を既にフォローしていれば外す。解いたら、次の突き合わせで返す。
    def test_sync_unfollows_stopped_accounts_and_follows_them_again_after_unblock
      @service.following = ['1', '2', '3']
      @repository.block('2', 'user2')

      assert_equal(['2'], subject.sync[:unfollowed])
      @service.following = ['1', '3']
      @repository.unblock('2')

      assert_equal(['2'], subject.sync[:followed])
    end

    # 🔴 **歯止めを超えたら 1 人も外さない**（一覧が欠けたときの事故を防ぐ）。
    def test_sync_unfollows_nobody_over_the_limit
      config['/chat/follow/unfollow_limit'] = 2
      @followers = []
      @service.following = ['1', '2', '3']

      assert_empty(subject.sync[:unfollowed])
      assert_empty(@service.unfollowed)
    end

    # ⚠ 歯止めに掛かっても、返すほうは続ける。
    def test_sync_still_follows_over_the_limit
      config['/chat/follow/unfollow_limit'] = 0
      @service.following = ['1', '2', '4']

      assert_equal(['3'], subject.sync[:followed])
      assert_empty(@service.unfollowed)
    end

    # 🔴 **1 人に断られても、その回の残りは続ける**（引っ越した・凍結された相手・リリース前レビューの赤）。
    def test_sync_continues_after_a_refused_follow
      @service.refused = ['2']

      assert_equal(['1', '3'], subject.sync[:followed].sort)
      assert_equal(['1', '3'], @service.followed.sort)
    end

    # ⚠ どちらかの一覧が引けなければ何もしない。
    def test_sync_does_nothing_without_both_lists
      @followers = nil

      assert_nil(subject.sync)
      @followers = ['1']
      @service.following = nil

      assert_nil(subject.sync)
      assert_empty(@service.followed)
      assert_empty(@service.unfollowed)
    end

    # ⚠ **承認待ちの相手に送り直さない**（鍵の掛かった相手はフォロー中の一覧に出ない）。
    def test_sync_does_not_resend_pending_requests
      @service.locked = ['3']
      @service.following = ['1', '2']

      assert_equal(['3'], subject.sync[:followed])
      assert_empty(subject.sync[:followed])
      assert_equal(['3'], @service.followed)
    end

    def test_follow_notification_reaches_the_follower
      follow_back!
      listener = MentionListener.new(service: Object.new, follower: subject)
      listener.on_follow({'id' => 'n1', 'account' => {'id' => '9', 'acct' => 'fan'}})

      assert_equal(['9'], @service.followed)
    end

    def test_disabled
      config['/chat/follow/enabled'] = false

      assert_false(FollowSync.enabled?)
      assert_nil(subject.start)
    end

    # 🔴 **待ちの設定が読めなくてもスレッドを死なせない**（#611）。⚠ 既定の待ちに倒す。
    def test_a_bad_interval_does_not_kill_the_thread
      waits = []
      sync = FollowSync.new(service: @service, roster: @roster, repository: @repository,
        sleeper: ->(seconds) {waits.push(seconds) && sync.stop})
      config['/chat/followers/refresh'] = '30x'
      sync.run

      assert_equal([FollowSync::FALLBACK_INTERVAL], waits)
    end

    # 🔴 **歯止めを超えたら痕跡に残し、Sentry は止まり始めた 1 回だけ**（#614）。⚠ 歯止めの内に戻れば消える。
    def test_over_the_limit_is_traced_and_reported_once
      FileUtils.rm_f(Heartbeat.path)
      config['/chat/follow/unfollow_limit'] = 2
      @followers = []
      @service.following = ['1', '2', '3']
      reported = []
      subject.define_singleton_method(:report_error) {|error, **| reported.push(error.message)}
      2.times {subject.sync}

      assert_equal(1, reported.size)
      assert_equal({count: 3, limit: 2}, Heartbeat.follow_over_limit.slice(:count, :limit))
      @service.following = ['1']
      subject.sync

      assert_nil(Heartbeat.follow_over_limit)
    ensure
      FileUtils.rm_f(Heartbeat.path)
    end

    # 🔴 **人が通すときは歯止めを外す**（#614・`makoto chat follow-sync --apply`）。
    def test_force_ignores_the_limit
      FileUtils.rm_f(Heartbeat.path)
      config['/chat/follow/unfollow_limit'] = 2
      @followers = []
      @service.following = ['1', '2', '3']
      subject.define_singleton_method(:report_error) {|*, **| nil}
      subject.sync

      assert_equal(['1', '2', '3'], subject.sync(force: true)[:unfollowed].sort)
      assert_nil(Heartbeat.follow_over_limit)
    ensure
      FileUtils.rm_f(Heartbeat.path)
    end

    # ⚠ 見るだけ（何もしない）。
    def test_preview
      config['/chat/follow/unfollow_limit'] = 2
      @service.following = ['1', '4']
      to_follow, to_unfollow = subject.preview

      assert_equal(['2', '3'], to_follow.to_a.sort)
      assert_equal(['4'], to_unfollow.to_a)
      assert_empty(@service.followed)
      assert_empty(@service.unfollowed)
    end
  end
end
