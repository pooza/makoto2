module Makoto
  # 日常の曲紹介（#16）。⚠⚠ **完了条件は「紹介文が `kind` に応じて破綻しないこと」と
  # 「キャラの一貫性を損なわない語り口」**の 2 つ。🔴 **前者はここと `SongSourceTest`、
  # 後者は前置きの原稿（`makoto-scripts`）が受ける。**
  class SongTest < TestCase
    def setup
      super
      @repository = MessageRepository.new(corpus_db)
      @tracks = TrackRepository.new(track_db)
    end

    def song(seed = 20_261_104)
      return Song.new(repository: @repository, tracks: @tracks, random: Random.new(seed))
    end

    def jst(month, day, hour = 12, year: 2026)
      return Time.new(year, month, day, hour, 0, 0, '+09:00')
    end

    # ⚠ 枠は 1 日 2 本（12:00 / 20:00）。**`finish` は含まない（半開区間）。**
    # 🔴 2026-09-04 オーナー判断。
    def test_timetable_has_two_slots_a_day
      times = song.timetable.times(Date.new(2026, 9, 1))

      assert_equal([jst(9, 1, 12), jst(9, 1, 20)], times)
    end

    # 🔴 **朝挨拶（08:00）・予告（10:00）・日曜の実況の窓（08:30〜09:00）のどれとも
    # 重ならない。**⚠⚠ **窓の検査そのものは `Scheduler#register`。**
    def test_the_default_slot_avoids_the_commentary_window
      assert_false(CommentaryWindow.new.conflict?(song.timetable))
    end

    def test_the_default_slot_is_accepted
      assert_equal(Song::NAME, song.job.name)
    end

    def test_job
      job = song.job

      assert_equal(Song::NAME, job.name)
      assert_equal(song.timetable.to_s, job.timetable.to_s)
    end

    # ⚠ 冪等キーは枠の頭から作る。⚠⚠ **12:00 JST は 03:00 UTC。**
    def test_idempotency_key_comes_from_the_slot
      assert_equal('song-20260901T030000Z', song.job.idempotency_key(jst(9, 1, 12)))
      assert_equal('song-20260901T110000Z', song.job.idempotency_key(jst(9, 1, 20)))
    end

    # 🔴 **前置きの type を記念日に登録させない。**⚠⚠ **登録すると通年の段から外れ、
    # その日以外は前置きを 1 本も引けなくなる** — ⚠ **曲だけが出続けるので、
    # 前置きが消えたことに誰も気づけない。**
    def test_rejects_the_type_registered_as_an_anniversary
      config['/song/type'] = config['/announcement/type']

      assert_raise(Ginseng::ConfigError) {song.job}
    end

    # ⚠ **アルバム名を主役にする kind**（→ `TrackPresenter`）。
    def test_collection_kinds
      assert_equal(['bgm', 'instrumental'], song.collection_kinds)
    end

    # ⚠⚠ **設定を消せば、どの kind でもアルバム名を出さない**（#77）。
    def test_collection_kinds_can_be_emptied
      config['/song/collection_kinds'] = []

      assert_equal([], song.collection_kinds)
    end

    # ⚠ **黙る日の type**（→ `SongSource#quiet?`）。
    def test_quiet_types
      assert_equal(['live_eve', 'live_open', 'live_close'], song.quiet_types)
    end

    # 🔴 **予約されていない type を書いたら起動時に落とす**（Codex の P1）。
    # ⚠⚠ **`quiet?` が永久に false になり、検査が黙って無効になる** —
    # ⚠ **表面化するのは 11/4 の 12:00**（**投稿は取り消せない**）。
    def test_rejects_a_quiet_type_that_is_not_reserved
      config['/song/quiet_types'] = ['live_open', 'live_typo']

      assert_raise(Ginseng::ConfigError) {song.job}
    end

    # ⚠ **設定を消せば検査も通る**（黙らなくなるだけ → #77）。
    def test_the_gate_can_be_emptied
      config['/song/quiet_types'] = []

      assert_equal(Song::NAME, song.job.name)
    end

    # ⚠ 抽選は #11 の重み付き（→ `TrackLottery`）。**母集合は `distinct` × `linkable`。**
    def test_the_lottery_draws_from_the_linkable_pool
      ids = Array.new(50) {song.lottery.draw[:id]}.uniq

      assert_not_include(ids, 1009)
      assert_not_include(ids, 1011)
    end
  end
end
