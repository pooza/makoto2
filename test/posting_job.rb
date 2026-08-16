module Makoto
  class PostingJobTest < TestCase
    def setup
      super
      @url = "#{config['/mastodon/url']}/api/v1/statuses"
      @date = Date.new(2026, 11, 4)
    end

    # ⚠ **枠の結末が `Heartbeat` に残るようになった**（#78）ので、痕跡を持ち越さない。
    setup {FileUtils.rm_f(Heartbeat.path)}
    teardown {FileUtils.rm_f(Heartbeat.path)}

    def timetable
      return Timetable.new(start: '12:00', finish: '20:00', interval: '2m', timezone: 'Asia/Tokyo')
    end

    def job(source = nil, **)
      return PostingJob.new(name: 'live', timetable: timetable, source: source || proc {'いくよ！'}, **)
    end

    def jst(hour, minute = 0, second = 0)
      return Time.new(@date.year, @date.month, @date.day, hour, minute, second, '+09:00')
    end

    def stub_post
      return stub_request(:post, @url).to_return(
        status: 200,
        headers: {'Content-Type' => 'application/json'},
        body: {id: '114514', url: "#{config['/mastodon/url']}/@test/114514"}.to_json,
      )
    end

    def test_posts_at_the_top_of_a_slot
      stub_post
      job.exec(jst(12, 0))

      assert_requested(:post, @url, times: 1, body: {status: 'いくよ！'})
    end

    # ⚠ tick はぴったりの時刻には来ない。拾う幅の内側なら投稿すること。
    def test_posts_within_tolerance
      stub_post
      job.exec(jst(12, 0, 9))

      assert_requested(:post, @url, times: 1)
    end

    # ⚠⚠ 枠の途中では投稿しない。tick は枠より細かく回るので、ここを外すと
    # 1 枠につき何通も出る。
    def test_does_not_post_between_slots
      stub_post
      job.exec(jst(12, 0, 30))
      job.exec(jst(12, 1))

      assert_not_requested(:post, @url)
    end

    def test_does_not_post_outside_the_window
      stub_post
      job.exec(jst(11, 59))
      # ⚠ 終了時刻ちょうども枠の外（20:00 は終了告知の枠）。
      job.exec(jst(20, 0))

      assert_not_requested(:post, @url)
    end

    def test_due
      assert_true(job.due?(jst(12, 0)))
      assert_true(job.due?(jst(12, 2, 9)))
      assert_false(job.due?(jst(12, 1)))
      assert_false(job.due?(jst(11, 59)))
    end

    # ⚠⚠ **枠から作る。**再起動や tick の重なりで同じ枠を 2 度処理しても、
    # Mastodon 側が畳んで 1 通に収まる。
    def test_idempotency_key_is_derived_from_the_slot
      keys = []
      stub_request(:post, @url).to_return do |request|
        keys.push(request.headers['Idempotency-Key'])
        {status: 200, headers: {'Content-Type' => 'application/json'}, body: '{}'}
      end
      job.exec(jst(12, 0))
      job.exec(jst(12, 0, 5))
      job.exec(jst(12, 2))

      assert_equal(3, keys.size)
      # 同じ枠なら同じキー。⚠ 別プロセスでも同じ値になること（時刻だけから作る）。
      assert_equal(keys[0], keys[1])
      assert_not_equal(keys[0], keys[2])
      assert_include(keys[0], 'live')
    end

    # ⚠⚠ 同じ枠なら本文が変わってもキーが変わらない（抽選をやり直しても二重に
    # 出ない）。
    def test_idempotency_key_ignores_the_text
      slot = timetable.slot_at(jst(12, 0))
      changing = job(proc {SecureRandom.uuid})

      assert_equal(changing.idempotency_key(slot), job.idempotency_key(slot))
    end

    # ⚠⚠ 本文が作れなくても常駐を落とさない。その枠は欠落したまま次へ進む。
    def test_source_error_does_not_raise
      stub_post
      broken = job(proc {raise Ginseng::GatewayError, 'LLM down'})

      assert_nothing_raised {broken.exec(jst(12, 0))}
      assert_not_requested(:post, @url)
    end

    # 本文が無いのは異常ではない（原稿が無い日など）。投稿しないだけ。
    def test_blank_text_is_not_posted
      stub_post
      empty = job(proc {''})

      assert_nil(empty.exec(jst(12, 0)))
      assert_not_requested(:post, @url)
    end

    # ⚠⚠ **投稿が失敗しても常駐を落とさない。**ここで例外を上げると、ライブ当日に
    # 1 本の失敗で残りの枠を全部落とす。
    def test_post_error_does_not_raise
      stub_request(:post, @url).to_return(status: 401, body: '{}')

      assert_nothing_raised {job.exec(jst(12, 0))}
      assert_requested(:post, @url, times: 1)
    end

    def test_passes_visibility
      stub_post
      job(nil, visibility: :unlisted).exec(jst(12, 0))

      assert_requested(:post, @url, times: 1, body: {status: 'いくよ！', visibility: 'unlisted'})
    end

    # 枠の頭の時刻が source に渡ること。⚠ 原稿の選択（#12）が日付を見る。
    def test_source_receives_the_slot
      stub_post
      slots = []
      job(proc {|slot| slots.push(slot) && 'ok'}).exec(jst(12, 2))

      assert_equal(1, slots.size)
      assert_equal(timetable.slot_at(jst(12, 2)), slots.first)
    end

    # ⚠⚠ 拾う幅より短い間隔の枠は取りこぼす。起動時に弾くこと（無言で投稿が
    # 減るのが一番まずい）。
    def test_rejects_interval_shorter_than_tolerance
      assert_raise(Ginseng::ConfigError) do
        PostingJob.new(
          name: 'too_fast',
          timetable: Timetable.new(
            start: '12:00', finish: '20:00', interval: '5s', timezone: 'Asia/Tokyo',
          ),
          source: proc {'ok'},
        )
      end
    end

    def test_rejects_source_without_call
      assert_raise(Ginseng::ConfigError) do
        PostingJob.new(name: 'broken', timetable: timetable, source: 'いくよ！')
      end
    end

    def test_rejects_bad_tolerance
      assert_raise(Ginseng::ConfigError) do
        PostingJob.new(name: 'live', timetable: timetable, source: proc {'ok'}, tolerance: 'soon')
      end
    end

    # ⚠⚠ **既定は `/scheduler/tick` ではなく `/scheduler/tolerance`**（#90 / #80 の黄 8）。
    # ⚠ **同値だと拾えるのは tick が `[枠の頭, 枠の頭+tick)` に落ちたときだけで、
    # 余裕が構造的にゼロ**になる。
    def test_tolerance_comes_from_config
      assert_equal(Fugit::Duration.parse(config['/scheduler/tolerance']).to_sec, job.tolerance)
      assert_operator(job.tolerance, :>, Fugit::Duration.parse(config['/scheduler/tick']).to_sec)
    end

    # ⚠⚠ **tick が遅れて来ても枠を拾えること。**⚠ **ライブの枠間隔 180 秒は tick の
    # 10 秒の整数倍なので、位相ずれは 160 枠すべてに同じように効く**（1 枠だけの
    # 事故にならない）。
    def test_a_late_tick_still_catches_the_slot
      assert(job.due?(jst(12, 0) + 20))
      # ⚠ 幅を越えれば拾わない（枠の途中で投稿しない、は保たれること）。
      refute(job.due?(jst(12, 0) + 40))
    end

    # ⚠⚠ **ここから #78。**「投稿が実際に出たか」を痕跡に残す。**`jobs` は起動時に
    # 決まる登録の本数なので、160 枠が全滅しても動かない。**

    def test_records_a_success
      stub_post
      job.exec(jst(12, 0))

      assert_equal(0, Heartbeat.failures)
      assert_not_nil(Heartbeat.posted_at)
    end

    def test_records_a_failure_when_the_post_fails
      stub_request(:post, @url).to_return(status: 401, body: '{}')
      job.exec(jst(12, 0))
      job.exec(jst(12, 2))

      assert_equal(2, Heartbeat.failures)
      assert_nil(Heartbeat.posted_at)
      assert_not_nil(Heartbeat.failed_at)
    end

    # ⚠⚠ **#78 の核心。**`source` が落ちた枠は**「原稿が無い日」と同じ形（本文 nil）で
    # 出てくる**ので、そこで区別を付けないと **#77 のような設定の欠落が中立に紛れる。**
    def test_records_a_failure_when_the_source_raises
      stub_post
      broken = job(proc {raise Ginseng::ConfigError, 'missing key'})
      broken.exec(jst(12, 0))

      assert_equal(1, Heartbeat.failures)
      assert_not_requested(:post, @url)
    end

    # ⚠⚠ **本文が無いのは中立。**⚠ **これを失敗に数えると、原稿がまだ無い
    # 8/15〜10/31 の 2 か月半がずっと警告になる。**
    def test_blank_text_is_neither_success_nor_failure
      stub_post
      empty = job(proc {''})
      empty.exec(jst(12, 0))
      empty.exec(jst(12, 2))

      assert_equal(0, Heartbeat.failures)
      assert_nil(Heartbeat.posted_at)
    end

    # ⚠ **枠の外では何も記録しない。**tick は枠より細かく回るので、ここで数えると
    # 失敗が実際の枠数と無関係に膨らむ。
    def test_records_nothing_outside_a_slot
      stub_post
      job.exec(jst(12, 1))

      assert_equal(0, Heartbeat.failures)
      assert_nil(Heartbeat.posted_at)
    end

    # ⚠⚠ **同じ枠を 2 度数えない**（#81 の Codex 指摘・実測で 2 進んでいた）。
    # ⚠ **`Scheduler` は登録直後に初回 tick を叩いてから `every` で回す**ので、
    # **拾う幅の内側で同じ枠が 2 回来る。再起動が挟まれば毎回そうなる。**
    # ⚠⚠ **成功は冪等キーで Mastodon 側が畳むのに、失敗だけ二重に数えると、
    # 落ちた枠 1 つで閾値を 2 つ消費する。**
    def test_the_same_slot_is_counted_once
      stub_request(:post, @url).to_return(status: 401, body: '{}')
      job.exec(jst(12, 0))
      job.exec(jst(12, 0, 5))

      assert_requested(:post, @url, times: 2)
      assert_equal(1, Heartbeat.failures)
    end

    # ⚠ **別の枠なら別に数える**（畳みすぎて検知が鈍らないこと）。
    def test_different_slots_are_counted_separately
      stub_request(:post, @url).to_return(status: 401, body: '{}')
      job.exec(jst(12, 0))
      job.exec(jst(12, 2))
      job.exec(jst(12, 4))

      assert_equal(3, Heartbeat.failures)
    end

    # ⚠ **`source` が落ちた枠も同じく 1 回。**投稿の失敗と経路が違うので別に見る。
    def test_the_same_slot_is_counted_once_when_the_source_raises
      broken = job(proc {raise Ginseng::ConfigError, 'missing key'})
      broken.exec(jst(12, 0))
      broken.exec(jst(12, 0, 5))

      assert_equal(1, Heartbeat.failures)
    end

    # ⚠ **1 本出れば数え直し。**復旧したのに警告が残り続けないこと。
    def test_a_success_resets_the_failures
      stub_request(:post, @url).to_return(status: 401, body: '{}')
      job.exec(jst(12, 0))
      job.exec(jst(12, 2))

      assert_equal(2, Heartbeat.failures)

      stub_post
      job.exec(jst(12, 4))

      assert_equal(0, Heartbeat.failures)
    end

    # ⚠⚠ **痕跡が書けなくても枠を落とさない。**監視のための書き込みが投稿を
    # 巻き込むと、**監視を足したせいで壊れる。**
    def test_a_broken_heartbeat_does_not_break_the_post
      stub_post
      # ⚠⚠ **`remove_method` で戻さない。**`record_success` は `class << self` の本体
      # なので、消すと**このテストより後ろの全部から失われる**（実際に踏んだ）。
      # ⚠ **元の Method を持っておいて defineし直す**（`test/health.rb` と同じ形）。
      original = Heartbeat.method(:record_success)
      Heartbeat.define_singleton_method(:record_success) {|*| raise Errno::EACCES, 'read-only'}
      begin
        assert_nothing_raised {job.exec(jst(12, 0))}
        assert_requested(:post, @url, times: 1)
      ensure
        Heartbeat.define_singleton_method(:record_success, original)
      end
    end
  end
end
