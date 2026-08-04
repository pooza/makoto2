module Makoto
  class TimetableTest < TestCase
    # ライブの枠（→ docs/birthday-live.md）。12:00 開始・20:00 終了・2 分間隔。
    def live
      return Timetable.new(start: '12:00', finish: '20:00', interval: '2m', timezone: 'Asia/Tokyo')
    end

    def jst(date, hour, minute = 0)
      return Time.new(date.year, date.month, date.day, hour, minute, 0, '+09:00')
    end

    def date
      return Date.new(2026, 11, 4)
    end

    def test_times_are_half_open
      times = live.times(date)

      assert_equal(jst(date, 12, 0), times.first)
      # ⚠ 20:00 は終了告知の枠なので含まない。含めると告知と曲が重なる。
      assert_equal(jst(date, 19, 58), times.last)
      assert_equal(240, times.size)
    end

    def test_times_are_evenly_spaced
      times = live.times(date)
      gaps = times.each_cons(2).map {|a, b| b - a}.uniq

      assert_equal([120.0], gaps)
    end

    # ⚠ 割り切れない間隔でも枠をはみ出さない。
    def test_times_never_exceed_finish
      timetable = Timetable.new(
        start: '12:00', finish: '12:10', interval: '3m', timezone: 'Asia/Tokyo',
      )
      times = timetable.times(date)

      assert_equal([jst(date, 12, 0), jst(date, 12, 3), jst(date, 12, 6), jst(date, 12, 9)], times)
    end

    def test_size
      assert_equal(240, live.size(date))
    end

    def test_cover
      assert_true(live.cover?(jst(date, 12, 0)))
      assert_true(live.cover?(jst(date, 19, 59)))
      assert_false(live.cover?(jst(date, 11, 59)))
      # ⚠ 終了時刻ちょうどは枠の外。
      assert_false(live.cover?(jst(date, 20, 0)))
    end

    # 「再起動後の状態復帰」の中身。時刻さえ分かれば続きの位置が出る。
    def test_index_at
      assert_equal(0, live.index_at(jst(date, 12, 0)))
      assert_equal(0, live.index_at(jst(date, 12, 1)))
      assert_equal(1, live.index_at(jst(date, 12, 2)))
      assert_equal(239, live.index_at(jst(date, 19, 59)))
    end

    # ⚠ 枠の頭の時刻。投稿の冪等キーがこれから作られる（→ PostingJob）。
    def test_slot_at
      assert_equal(jst(date, 12, 0), live.slot_at(jst(date, 12, 0)))
      assert_equal(jst(date, 12, 0), live.slot_at(jst(date, 12, 1)))
      assert_equal(jst(date, 12, 2), live.slot_at(jst(date, 12, 2)))
      assert_equal(jst(date, 19, 58), live.slot_at(jst(date, 19, 59)))
    end

    def test_slot_at_outside_window
      assert_nil(live.slot_at(jst(date, 11, 59)))
      assert_nil(live.slot_at(jst(date, 20, 0)))
    end

    def test_index_at_outside_window
      assert_nil(live.index_at(jst(date, 11, 59)))
      assert_nil(live.index_at(jst(date, 20, 0)))
    end

    # ⚠ 同じ時刻を何度渡しても同じ答えが返る。落ちて戻ってきても位置がずれないこと。
    def test_index_is_deterministic
      time = jst(date, 15, 33)

      assert_equal(live.index_at(time), live.index_at(time))
      assert_equal(live.index_at(time), Timetable.new(
        start: '12:00', finish: '20:00', interval: '2m', timezone: 'Asia/Tokyo',
      ).index_at(time))
    end

    def test_next_after
      assert_equal(jst(date, 12, 2), live.next_after(jst(date, 12, 0)))
      assert_equal(jst(date, 12, 2), live.next_after(jst(date, 12, 1)))
      assert_equal(jst(date, 12, 0), live.next_after(jst(date, 3, 0)))
    end

    # 枠を過ぎたら翌日の 1 本目へ送る。常駐は落とさずに翌日を待つ。
    def test_next_after_rolls_over
      assert_equal(jst(date + 1, 12, 0), live.next_after(jst(date, 20, 0)))
    end

    # ⚠⚠ タイムゾーンはホストの TZ に依存しない。UTC のホストで 12:00 JST を
    # 計算しても 03:00 UTC を指すこと。ここがずれると「起動したのに何も起きない」。
    def test_timezone_is_explicit
      time = live.times(date).first

      assert_equal(3, time.getutc.hour)
      assert_equal(0, time.getutc.min)
      assert_equal(date, time.getutc.to_date)
    end

    def test_timezone_changes_the_instant
      utc = Timetable.new(start: '12:00', finish: '20:00', interval: '2m', timezone: 'UTC')

      assert_equal(12, utc.times(date).first.getutc.hour)
      assert_not_equal(live.times(date).first, utc.times(date).first)
    end

    # ⚠ 設定の誤りは「起動して何も起きない」ではなく例外にする。
    def test_rejects_reversed_window
      assert_raise(Ginseng::ConfigError) do
        Timetable.new(start: '20:00', finish: '12:00', interval: '2m', timezone: 'Asia/Tokyo')
      end
    end

    def test_rejects_empty_window
      assert_raise(Ginseng::ConfigError) do
        Timetable.new(start: '12:00', finish: '12:00', interval: '2m', timezone: 'Asia/Tokyo')
      end
    end

    def test_rejects_bad_clock
      ['12', '12:0', '25:00', '12:60', '', 'noon'].each do |value|
        assert_raise(Ginseng::ConfigError) do
          Timetable.new(start: value, finish: '20:00', interval: '2m', timezone: 'Asia/Tokyo')
        end
      end
    end

    # ⚠ 0 秒を通すと times が無限ループする。設定の誤りで常駐が固まらないこと。
    def test_rejects_non_positive_interval
      ['0s', '0'].each do |value|
        assert_raise(Ginseng::ConfigError) do
          Timetable.new(start: '12:00', finish: '20:00', interval: value, timezone: 'Asia/Tokyo')
        end
      end
    end

    def test_rejects_bad_interval
      assert_raise(Ginseng::ConfigError) do
        Timetable.new(start: '12:00', finish: '20:00', interval: 'soon', timezone: 'Asia/Tokyo')
      end
    end

    def test_rejects_unknown_timezone
      assert_raise(Ginseng::ConfigError) do
        Timetable.new(start: '12:00', finish: '20:00', interval: '2m', timezone: 'Asia/Nowhere')
      end
    end

    # タイムゾーンを省略したら設定から取る。⚠ ホストの TZ ではない。
    def test_timezone_defaults_to_config
      timetable = Timetable.new(start: '12:00', finish: '20:00', interval: '2m')

      assert_equal(config['/scheduler/timezone'], timetable.timezone.identifier)
    end

    def test_to_s
      assert_equal('12:00-20:00/120s (Asia/Tokyo)', live.to_s)
    end
  end
end
