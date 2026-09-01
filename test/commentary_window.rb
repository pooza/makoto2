module Makoto
  # 日曜 08:30〜09:00 の実況の窓（#172）。⚠⚠ **ここが黙って効かなくなると、
  # 人が話しているところへ定型文を差し込んだ後でしか気づけない。**
  class CommentaryWindowTest < TestCase
    def window
      return CommentaryWindow.new
    end

    # 2026-11-01 は日曜。⚠ 窓は曜日で決まるので、日付そのものには意味が無い。
    def sunday(hour, minute = 0)
      return Time.new(2026, 11, 1, hour, minute, 0, '+09:00')
    end

    def monday(hour, minute = 0)
      return Time.new(2026, 11, 2, hour, minute, 0, '+09:00')
    end

    def timetable(start, finish)
      return Timetable.new(start: start, finish: finish, interval: '1m')
    end

    def test_covers_the_window_on_the_weekday
      assert_true(window.cover?(sunday(8, 30)))
      assert_true(window.cover?(sunday(8, 59)))
    end

    # ⚠ **終わりは含まない（半開区間）。**⚠⚠ **`Timetable` と規則を揃える。**
    def test_does_not_cover_the_finish
      assert_false(window.cover?(sunday(9, 0)))
      assert_false(window.cover?(sunday(8, 29)))
    end

    # ⚠⚠ **曜日も見る。**平日の 08:30 は実況の時間ではない。
    def test_other_weekdays_are_not_covered
      assert_false(window.cover?(monday(8, 45)))
    end

    # ⚠ 朝挨拶の 07:00 は窓の外（→ config）。
    def test_the_morning_slot_does_not_conflict
      assert_false(window.conflict?(timetable('07:00', '07:01')))
    end

    # 🔴 **窓に落ちる枠は検出する。**⚠⚠ **枠は日付を区別しない**ので、平日に走らせても
    # 日曜の窓に当たることが分かる。
    def test_a_slot_inside_the_window_conflicts
      assert_true(window.conflict?(timetable('08:45', '08:46')))
    end

    # ⚠ **枠が窓を跨ぐ場合も、窓の中に投稿の時刻があれば検出する。**
    def test_a_slot_that_steps_into_the_window_conflicts
      assert_true(window.conflict?(timetable('08:00', '09:30')))
    end

    # ⚠⚠ **窓の外を跨ぐだけの枠は検出しない**（08:00 と 09:00 の 2 本で窓には入らない）。
    def test_a_slot_that_steps_over_the_window_does_not_conflict
      assert_false(window.conflict?(Timetable.new(start: '08:00', finish: '10:00',
        interval: '1h')))
    end

    # ⚠⚠ **逆に書かれた窓は「常に外」になり、検査そのものが黙って効かなくなる。**
    # ⚠ 設定の側で止める。
    def test_rejects_a_reversed_window
      config['/commentary/finish'] = '08:00'

      assert_raise(Ginseng::ConfigError) {window.cover?(sunday(8, 45))}
    end

    # 🔴 **範囲の外の曜日で fail-open にしない**（Codex の P2）。⚠⚠ **`7` だと `cover?`
    # が何にも当たらず、検査そのものが黙って無効になる。**⚠ **schema は報告するが、
    # `validate_config` は記録して起動を続ける**（#99）ので、ここで落とす。
    def test_rejects_a_weekday_out_of_range
      config['/commentary/weekday'] = 7

      assert_raise(Ginseng::ConfigError) {window.cover?(sunday(8, 45))}
    end

    def test_rejects_a_bad_clock
      config['/commentary/start'] = '8時半'

      assert_raise(Ginseng::ConfigError) {window.cover?(sunday(8, 45))}
    end

    # 🔴 **夏時間の切り替え日だけを見ると検査が素通りする**（Codex の P2）。
    # ⚠⚠ **切り替え日には「存在しない時刻」がある**ので、⚠ **枠の時刻が切り替わりの
    # 瞬間へ寄せられて窓から外れる**（→ `Timetable#instant`）。⚠ **2 週ぶん見る。**
    #
    # ⚠ `America/New_York` の 2027-03-14 が春の切り替え（02:00 → 03:00）。
    def test_conflict_looks_past_a_dst_transition
      config['/scheduler/timezone'] = 'America/New_York'
      config['/commentary/start'] = '02:30'
      config['/commentary/finish'] = '03:00'

      Timecop.freeze(Time.utc(2027, 3, 9, 12, 0)) do
        assert_true(window.conflict?(timetable('02:45', '02:46')))
      end
    end

    def test_to_s
      assert_equal('Sunday 08:30-09:00 (Asia/Tokyo)', window.to_s)
    end
  end
end
