module Makoto
  class FollowerRosterTest < TestCase
    def setup
      @now = Time.new(2026, 11, 8, 12, 0, 0, '+09:00')
      @calls = 0
      @list = ['1', '2']
    end

    def roster(fetcher: nil)
      return FollowerRoster.new(
        fetcher: fetcher || -> {(@calls += 1) && @list},
        clock: -> {@now},
      )
    end

    def test_include
      subject = roster

      assert_true(subject.include?('1'))
      assert_true(subject.include?(2))
      assert_false(subject.include?('3'))
      assert_equal(1, @calls)
    end

    # ⚠ **フォローを外したことは、引き直しで拾う**（`/chat/followers/refresh`）。
    def test_refresh_after_the_interval
      subject = roster
      subject.include?('1')
      @list = ['2']
      @now += 60

      assert_true(subject.include?('1'))
      @now += 3600

      assert_false(subject.include?('1'))
      assert_equal(2, @calls)
    end

    # 🔴 **一度も引けていなければ例外**（空の一覧で「フォロワーでない」と答えない）。
    def test_never_loaded_raises
      subject = roster(fetcher: -> {raise Ginseng::GatewayError, 'down'})

      assert_raise(Ginseng::GatewayError) {subject.include?('1')}
    end

    # ⚠ **引き直しに失敗したら、前の一覧を使い続ける。**
    def test_keeps_the_old_list_when_a_refresh_fails
      fail_now = false
      subject = roster(fetcher: -> {fail_now ? raise(Ginseng::GatewayError, 'down') : @list})
      subject.include?('1')
      fail_now = true
      @now += 7200

      assert_true(subject.include?('1'))
    end

    # 🔴 **フォローの通知ですぐ足す。**⚠ 一度も引けていなければ何もしない。
    def test_add
      subject = roster
      subject.add('9')
      subject.refresh
      subject.add('9')

      assert_true(subject.include?('9'))
      assert_equal(3, subject.size)
    end

    # 🔴 **引き直しの最中に来たフォローを、差し替えで消さない**（v1.0.0 のリリース前レビュー）。
    def test_a_follow_during_refresh_is_kept
      subject = nil
      subject = roster(fetcher: -> {subject.add('9') && ['1', '2']})
      subject.refresh

      assert_true(subject.include?('9'))
      assert_equal(3, subject.size)
    end

    # ⚠ **重なった引き直しは 1 本ずつ**（PR #618 の Codex の P2）。両方とも引けた扱いになる。
    def test_overlapping_refreshes_are_serialized
      gate = Thread::Queue.new
      calls = 0
      subject = roster(fetcher: -> {(calls += 1) == 1 ? (gate.pop && ['1']) : ['1', '2']})
      first = Thread.new {subject.refresh}
      Thread.pass until first.status == 'sleep'
      second = Thread.new {subject.refresh}
      Thread.pass until ['sleep', false].include?(second.status)
      gate.push(true)

      assert_equal([1, 2], [first.value, second.value])
      assert_equal(2, subject.size)
    end
  end
end
