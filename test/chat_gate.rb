module Makoto
  class ChatGateTest < TestCase
    def setup
      @repository = ChatRepository.new(empty_db)
      @followers = ['1']
    end

    def now
      return Time.new(2026, 11, 8, 12, 0, 0, '+09:00')
    end

    def gate
      return ChatGate.new(repository: @repository, followed_by: ->(id) {@followers.include?(id)})
    end

    def account(id = '1', bot: false)
      return {'id' => id, 'acct' => "user#{id}", 'bot' => bot}
    end

    def respond_times(count, at: now - 60, id: '1')
      count.times {@repository.record(id, "user#{id}", :respond, at)}
    end

    def test_a_follower_gets_a_response
      decision = gate.decide(account, now: now)

      assert_true(decision.respond?)
    end

    # 🔴 **フォロワーでなければ、話せる条件を伝える**（2026-11-07・オーナー）。⚠ **1 日 1 回まで。**
    def test_a_non_follower_is_asked_to_follow_once_a_day
      first = gate.decide(account('2'), now: now)
      gate.record(account('2'), first, now: now)
      second = gate.decide(account('2'), now: now + 60)

      assert_equal(:ask_follow, first.action)
      assert_true(first.notice?)
      assert_equal([:silent, :not_follower], [second.action, second.reason])
      assert_equal(:ask_follow, gate.decide(account('2'), now: now + ChatGate::DAY + 1).action)
    end

    # ⚠ **フォロワーかが分からなければ黙る**（「フォロワーでない」に倒さない）。
    def test_unknown_followers_mean_silence
      broken = ChatGate.new(repository: @repository, followed_by: ->(_) {raise Ginseng::GatewayError, 'x'})
      decision = broken.decide(account('2'), now: now)

      assert_equal([:silent, :followers_unknown], [decision.action, decision.reason])
    end

    # ⚠ **ボットには、フォロワーでも返さない**（ボット同士の応酬を止める）。
    def test_a_bot_is_ignored
      decision = gate.decide(account('1', bot: true), now: now)

      assert_equal([:silent, :bot], [decision.action, decision.reason])
    end

    # 🔴 **相手ごとの上限: 1 時間に 3 回**。⚠ 届いたら決まった文を 1 回だけ、あとは黙る。
    def test_the_hourly_limit
      respond_times(3)
      first = gate.decide(account, now: now)
      gate.record(account, first, now: now)
      second = gate.decide(account, now: now + 60)

      assert_equal(:limit_notice, first.action)
      assert_equal([:silent, :account_limit], [second.action, second.reason])
      # ⚠ 1 時間たてば窓から外れる。
      assert_true(gate.decide(account, now: now + ChatGate::HOUR).respond?)
    end

    # 🔴 **1 日に 10 回。**⚠⚠ 時間の窓が空いても、日の窓で伝えたら翌日まで黙る。
    def test_the_daily_limit
      respond_times(10, at: now - (5 * ChatGate::HOUR))
      first = gate.decide(account, now: now)
      gate.record(account, first, now: now)

      assert_equal(:limit_notice, first.action)
      assert_true(gate.decide(account, now: now + (2 * ChatGate::HOUR)).silent?)
    end

    # 🔴 **全体の 1 日の上限**（暴走したときの歯止め）。⚠ 決まった文も返さない。
    def test_the_global_limit
      config['/chat/limit/global/day'] = 5
      5.times {|i| @repository.record("x#{i}", "x#{i}", :respond, now - 60)}
      decision = gate.decide(account, now: now)

      assert_equal([:silent, :global_limit], [decision.action, decision.reason])
    end

    # 🔴 **印の回数でペナルティを延ばす**（1 日 → 3 日 → 7 日・尽きたら最後のもの）。
    def test_penalty_grows_with_marks
      untils = Array.new(4) do |i|
        at = now + (i * 60)
        gate.mark(account, reason: 'prompt_injection', status_url: 'https://example.com/1', now: at)[:until_at] - at
      end

      assert_equal([1, 3, 7, 7].map {|d| d * ChatGate::DAY}, untils.map(&:round))
      assert_equal(4, @repository.penalty('1')[:marks])
    end

    def test_a_penalized_follower_is_ignored_until_it_expires
      gate.mark(account, reason: 'backstage', now: now)

      assert_equal([:silent, :penalty], gate.decide(account, now: now + 60).to_h.values)
      assert_true(gate.decide(account, now: now + ChatGate::DAY + 1).respond?)
    end

    # ⚠ **消せば印の回数も 0 に戻る**（判定の間違いを直す）。
    def test_forgive
      gate.mark(account, reason: 'backstage', now: now)
      @repository.forgive(@repository.find_penalty_by_acct('@user1')[:account_id])

      assert_true(gate.decide(account, now: now + 60).respond?)
      assert_nil(@repository.penalty('1'))
    end

    # ⚠ **黙ったときは数えない**（数えるのは返したものだけ）。
    def test_silence_is_not_recorded
      gate.record(account, ChatGate::Decision.new(action: :silent, reason: :bot), now: now)

      assert_equal(0, @repository.events.count)
    end
  end
end
