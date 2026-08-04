module Makoto
  class SchedulerTest < TestCase
    setup do
      Scheduler.instance.clear
    end

    teardown do
      Scheduler.instance.clear
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
  end
end
