module Makoto
  # 曲紹介の下見（#16）。⚠⚠ **曲は抽選なので「次に何が出るか」は言い当てられない。**
  # 🔴 **言い当てられるのは前置きだけ** — ⚠ **したがってここが見せるのは、前置きの
  # 並びと、`kind` ごとに実際に組んだ本文。**
  class SongCommandTest < TestCase
    def setup
      super
      @repository = MessageRepository.new(corpus_db)
      @tracks = TrackRepository.new(track_db)
    end

    def song
      @song ||= Song.new(repository: @repository, tracks: @tracks, random: Random.new(20_261_104))
      return @song
    end

    def command(options = {})
      subject = SongCommand.new
      subject.options = {days: SongCommand::DEFAULT_DAYS, count: 1}.merge(options)
      subject.instance_variable_set(:@song, song)
      subject.instance_variable_set(:@repository, @tracks)
      return subject
    end

    def capture
      original = $stdout
      $stdout = StringIO.new
      yield
      return $stdout.string
    ensure
      $stdout = original
    end

    def add_prefixes(count)
      count.times {|i| @repository.create(type: config['/song/type'], body: "前置き #{i}")}
    end

    # ⚠ 日付を渡した日から順に、1 日ぶんずつ出る。
    def test_preview_prints_a_day_each
      output = capture {command(date: '2026-09-01', days: 3).preview}

      assert_equal(['2026-09-01 (Tue)', '2026-09-02 (Wed)', '2026-09-03 (Thu)'],
        output.lines.map(&:chomp).grep(/\A\d{4}-/))
    end

    # ⚠⚠ **1 日 2 本の枠がそのまま見える。**
    def test_preview_shows_both_slots
      output = capture {command(date: '2026-09-01', days: 1).preview}

      assert_equal(2, output.lines.count {|line| line.match?(/\A {2}\d{2}:\d{2} /)})
      assert_include(output, '12:00')
      assert_include(output, '20:00')
    end

    # 🔴 **前置きごと出す。**⚠⚠ **下見で前置きが見えないと、実際の投稿と別物を読む
    # ことになる**（→ `SongSource`）。
    def test_preview_shows_the_prefix
      add_prefixes(4)
      output = capture {command(date: '2026-09-01', days: 1).preview}

      assert_match(/前置き \d/, output)
    end

    # ⚠ **前置きが 0 件でも下見は成り立つ**（曲だけが出る）。
    def test_preview_without_any_prefix
      output = capture {command(date: '2026-09-01', days: 1).preview}

      assert_include(output, '前置きはありません')
      assert_include(output, '♪ ')
    end

    def test_preview_rejects_a_bad_day_count
      assert_raise(SystemExit) {capture {command(days: 0).preview}}
    end

    # 🔴 **#16 の完了条件（`kind` ごとに破綻しないこと）を目で当てる口。**
    def test_sample_covers_every_kind
      output = capture {command.sample}

      @tracks.count_by_kind(song.lottery.candidates).each_key do |kind|
        assert_include(output, "=== #{kind} ===")
      end
    end

    def test_sample_can_pick_one_kind
      output = capture {command(kind: 'bgm').sample}

      assert_include(output, '=== bgm ===')
      assert_not_include(output, '=== vocal ===')
    end

    # ⚠ **母集合に居ない kind は、黙って 0 件を出さずに落とす。**
    def test_sample_rejects_an_unknown_kind
      assert_raise(SystemExit) {capture {command(kind: 'nosuch').sample}}
    end

    # ⚠⚠ **枠・前置きの本数・抽選の母集合が 1 画面で見える。**
    def test_slot_shows_the_timetable_and_the_pool
      add_prefixes(4)
      output = capture {command.slot}

      assert_include(output, "#{Song::NAME}: ")
      assert_include(output, '1 日 2 本（12:00 / 20:00）')
      assert_include(output, '前置きの原稿: 4 本')
      assert_include(output, '抽選の母集合: ')
      assert_include(output, 'アルバム名を出す')
    end

    def test_slot_says_when_there_is_no_prefix
      output = capture {command.slot}

      assert_include(output, '前置きの原稿: 0 本')
    end
  end
end
