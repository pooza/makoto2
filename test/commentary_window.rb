module Makoto
  # 実況の窓（#172 / #255）。⚠⚠ **ここが黙って効かなくなると、
  # 人が話しているところへ定型文を差し込んだ後でしか気づけない。**
  class CommentaryWindowTest < TestCase
    # 🔴 **設定の既定の窓**（ニチアサ ＝ 強・夜実況 / 振り返り / MX 再放送 ＝ 弱）。
    def windows
      return CommentaryWindow.all.to_h {|window| [window.name, window]}
    end

    def window(entry = {})
      return CommentaryWindow.new(
        {'name' => 'test', 'weekdays' => [0], 'start' => '08:30', 'finish' => '09:00',
         'strength' => 'strong'}.merge(entry),
      )
    end

    # 2026-11-01 は日曜。⚠ 窓は曜日で決まるので、日付そのものには意味が無い。
    def sunday(hour, minute = 0)
      return Time.new(2026, 11, 1, hour, minute, 0, '+09:00')
    end

    def monday(hour, minute = 0)
      return Time.new(2026, 11, 2, hour, minute, 0, '+09:00')
    end

    def wednesday(hour, minute = 0)
      return Time.new(2026, 11, 4, hour, minute, 0, '+09:00')
    end

    def timetable(start, finish)
      return Timetable.new(start: start, finish: finish, interval: '1m')
    end

    # ⚠ 聞き取りの窓（2026-09-29・オーナー）。🔴 **強いのはニチアサだけ。**
    def test_the_configured_windows
      assert_equal(['mx', 'nichiasa', 'night', 'review'], windows.keys.sort)
      assert_equal(['nichiasa'], CommentaryWindow.strong.map(&:name))
      assert_equal(['mx', 'night', 'review'], CommentaryWindow.weak.map(&:name).sort)
      assert_equal([3, 4], windows['mx'].weekdays)
      assert_equal([6], windows['review'].weekdays)
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

    # 🔴 **曜日を省いた窓は毎日**（夜実況）。
    def test_a_window_without_weekdays_covers_every_day
      night = windows['night']

      assert_equal((0..6).to_a, night.weekdays)
      assert_true(night.cover?(sunday(20, 0)))
      assert_true(night.cover?(monday(20, 29)))
      assert_false(night.cover?(monday(20, 30)))
    end

    # ⚠ **曜日は複数書ける**（MX 再放送は水・木）。
    def test_a_window_on_several_weekdays
      mx = windows['mx']

      assert_true(mx.cover?(wednesday(19, 45)))
      assert_true(mx.cover?(Time.new(2026, 11, 5, 19, 30, 0, '+09:00')))
      assert_false(mx.cover?(monday(19, 45)))
    end

    # ⚠ 朝挨拶の 08:00 は窓の外（→ config・#247）。⚠⚠ **余裕は 29 分しかない。**
    def test_the_morning_slot_does_not_conflict
      assert_false(window.conflict?(timetable('08:00', '08:01')))
    end

    # 🔴 **窓に落ちる枠は検出する。**⚠⚠ **枠は日付を区別しない**ので、平日に走らせても
    # 日曜の窓に当たることが分かる。
    def test_a_slot_inside_the_window_conflicts
      assert_true(window.conflict?(timetable('08:45', '08:46')))
    end

    # ⚠ **曜日が複数あっても、どの曜日の重なりも拾う。**
    def test_conflict_looks_at_every_weekday
      assert_true(window('weekdays' => [3, 4]).conflict?(timetable('08:45', '08:46')))
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
      assert_raise(Ginseng::ConfigError) {window('finish' => '08:00').cover?(sunday(8, 45))}
    end

    # 🔴 **範囲の外の曜日で fail-open にしない**（Codex の P2）。⚠⚠ **`7` だと `cover?`
    # が何にも当たらず、検査そのものが黙って無効になる。**⚠ **schema は報告するが、
    # `validate_config` は記録して起動を続ける**（#99）ので、ここで落とす。⚠ **空の配列も同じ。**
    def test_rejects_weekdays_out_of_range
      assert_raise(Ginseng::ConfigError) {window('weekdays' => [7]).cover?(sunday(8, 45))}
      assert_raise(Ginseng::ConfigError) {window('weekdays' => []).cover?(sunday(8, 45))}
      assert_raise(Ginseng::ConfigError) {window('weekdays' => ['0']).cover?(sunday(8, 45))}
    end

    def test_rejects_a_bad_clock
      assert_raise(Ginseng::ConfigError) {window('start' => '8時半').cover?(sunday(8, 45))}
    end

    # 🔴 **知らない強さで fail-open にしない。**⚠⚠ **`strong?` も `weak?` も偽になり、
    # どちらの検査も黙って素通りする。**
    def test_rejects_an_unknown_strength
      assert_raise(Ginseng::ConfigError) {window('strength' => 'medium').strong?}
    end

    # 🔴 **窓が 1 つも無ければ落とす**（空だとどの枠も通る）。
    def test_rejects_no_windows
      config['/commentary/windows'] = []

      assert_raise(Ginseng::ConfigError) {CommentaryWindow.all}
    end

    # 🔴 **ライブの枠は弱い窓の検査から外す**（2026-11-06・オーナー判断）。
    def test_live_slots_are_weak_exempt
      [Live::NAME, Live::OPEN_NAME, Live::CLOSE_NAME, Live::EVE_NAME].each do |name|
        assert_true(CommentaryWindow.weak_exempt?(name))
      end
      assert_false(CommentaryWindow.weak_exempt?(Song::NAME))
    end

    # ⚠ **弱い窓との重なりは下見に出る**（`morning slot` / `song slot`）。
    def test_summary_warns_a_weak_conflict
      night = PostingJob.new(
        name: 'night',
        timetable: Timetable.new(start: '20:10', finish: '20:11', interval: '1m'),
        source: proc {'ok'},
      )

      assert_include(CommentaryWindow.summary(night), "  ⚠ 弱い窓と重なる: #{windows['night']}（投稿は止めない）")
      assert_false(CommentaryWindow.summary(Morning.new.job).any? {it.include?('⚠')})
    end

    # 🔴 **夏時間の切り替え日だけを見ると検査が素通りする**（Codex の P2）。
    # ⚠⚠ **切り替え日には「存在しない時刻」がある**ので、⚠ **枠の時刻が切り替わりの
    # 瞬間へ寄せられて窓から外れる**（→ `Timetable#instant`）。⚠ **2 週ぶん見る。**
    #
    # ⚠ `America/New_York` の 2027-03-14 が春の切り替え（02:00 → 03:00）。
    def test_conflict_looks_past_a_dst_transition
      config['/scheduler/timezone'] = 'America/New_York'
      dst = window('start' => '02:30', 'finish' => '03:00')

      Timecop.freeze(Time.utc(2027, 3, 9, 12, 0)) do
        assert_true(dst.conflict?(timetable('02:45', '02:46')))
      end
    end

    def test_to_s
      assert_equal('nichiasa Sunday 08:30-09:00 strong (Asia/Tokyo)', windows['nichiasa'].to_s)
      assert_equal('night every day 20:00-20:30 weak (Asia/Tokyo)', windows['night'].to_s)
      assert_equal('mx Wednesday,Thursday 19:30-20:00 weak (Asia/Tokyo)', windows['mx'].to_s)
    end
  end
end
