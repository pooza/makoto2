module Makoto
  class SchedulerTest < TestCase
    setup do
      Scheduler.instance.clear
    end

    teardown do
      Scheduler.instance.clear
      # ⚠ 単体テストの中で `every` を登録するので、外して次のテストに持ち越さない。
      Scheduler.instance.scheduler.jobs.each(&:unschedule)
    end

    def timetable
      return Timetable.new(start: '12:00', finish: '20:00', interval: '2m', timezone: 'Asia/Tokyo')
    end

    def job(name, source)
      return PostingJob.new(name: name, timetable: timetable, source: source)
    end

    def jst(hour, minute = 0)
      return Time.new(2026, 11, 4, hour, minute, 0, '+09:00')
    end

    def test_register
      assert_equal(Scheduler.instance, Scheduler.instance.register(job('live', proc {'ok'})))
    end

    def test_tick_runs_registered_jobs
      calls = []
      Scheduler.instance.register(job('live', proc {|slot| calls.push(slot) && nil}))
      Scheduler.instance.tick(jst(12, 0))
      Scheduler.instance.tick(jst(12, 1))

      # ⚠ 枠の頭だけ。枠の途中の tick では動かない。
      assert_equal(1, calls.size)
    end

    # ⚠⚠ **1 本の投稿が落ちても他を巻き込まない。**ライブ当日に 1 本の例外で
    # 残りの枠を全部落とすのが最悪の壊れ方。
    def test_tick_isolates_failures
      reached = []
      exploding = job('exploding', proc {'ok'})
      exploding.define_singleton_method(:exec) {|_time = nil| raise 'boom'}
      Scheduler.instance.register(exploding)
      Scheduler.instance.register(job('live', proc {reached.push(:live) && nil}))

      assert_nothing_raised {Scheduler.instance.tick(jst(12, 0))}
      assert_equal([:live], reached)
    end

    def test_tick_without_jobs
      assert_equal([], Scheduler.instance.tick(jst(12, 0)))
    end

    # ⚠⚠ **常駐の開始直後に 1 回叩くこと。**`every` は最初の間隔を待つので、これが
    # 無いと**枠の頭 ＋ tolerance の内側で再起動した枠が落ちる**（→ #47）。
    # ⚠ 枠に入っているかどうかの判定は `PostingJob` 側のテストが見るので、ここでは
    # **登録の仕方**（起動直後に叩くか）だけを見る。
    def test_schedule_posts_ticks_immediately
      calls = []
      recording = job('live', proc {'ok'})
      recording.define_singleton_method(:exec) {|_time = nil| calls.push(:exec) && nil}
      Scheduler.instance.register(recording)

      Scheduler.instance.send(:schedule_posts)

      assert_equal([:exec], calls)
    end

    # ⚠ 登録が 1 つも無ければ tick そのものを作らない。空回りのログを増やさない。
    def test_schedule_posts_without_jobs
      assert_nil(Scheduler.instance.send(:schedule_posts))
      assert_equal([], Scheduler.instance.scheduler.jobs)
    end
  end
end
