module Makoto
  class PostingJobTest < TestCase
    def setup
      super
      @url = "#{config['/mastodon/url']}/api/v1/statuses"
      @date = Date.new(2026, 11, 4)
    end

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

    def test_tolerance_comes_from_config
      assert_equal(Fugit::Duration.parse(config['/scheduler/tick']).to_sec, job.tolerance)
    end
  end
end
