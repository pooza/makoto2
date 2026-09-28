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

    def add_prefixes(count, type: nil)
      count.times {|i| @repository.create(type: type || config['/song/type'], body: "前置き #{i}")}
    end

    # ⚠ 日付を渡した日から順に、1 日ぶんずつ出る。
    def test_preview_prints_a_day_each
      output = capture {command(date: '2026-09-01', days: 3).preview}

      assert_equal(['2026-09-01 (Tue)', '2026-09-02 (Wed)', '2026-09-03 (Thu)'],
        output.lines.map(&:chomp).grep(/\A\d{4}-/))
    end

    # ⚠⚠ **1 日 3 本の枠がそのまま見える**（#292）。
    def test_preview_shows_every_slot
      output = capture {command(date: '2026-09-01', days: 1).preview}

      assert_equal(3, output.lines.count {|line| line.match?(/\A {2}\d{2}:\d{2} /)})
      assert_include(output, '12:00')
      assert_include(output, '15:30')
      assert_include(output, '19:00')
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

    # 🔴 **黙る日はそう書く**（Codex の P1）。⚠⚠ **枠だけを並べると、下見と実機が
    # 食い違う** — ⚠ **11/3 / 11/4 はライブが持っているので 1 通も出ない。**
    def test_preview_marks_the_quiet_days
      output = capture {command(date: '2026-11-03', days: 2).preview}

      assert_equal(2, output.lines.count {|line| line.include?('他の枠が持つ日なので出しません')})
      assert_include(output, 'live_eve')
      assert_include(output, 'live_open')
      assert_not_include(output, '♪ ')
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
      assert_include(output, '1 日 3 本（12:00 / 15:30 / 19:00）')
      assert_include(output, '前置きの原稿: 共通 4 本（song・一周 1.3 日')
      assert_include(output, '抽選の母集合: ')
      assert_include(output, 'アルバム名を出す')
    end

    # 🔴 **前置きの本数は `kind` の束ごとに出す**（#293）。⚠⚠ **種類別が 0 本の束は
    # 「共通だけ」と書く**（**書き忘れと、書き分けていないのが見分けられる**）。
    def test_slot_shows_the_prefixes_by_kind
      add_prefixes(4)
      add_prefixes(2, type: 'song_bgm')
      output = capture {command.slot}

      assert_include(output, '  bgm: song_bgm 2 本（共通と本数の比で引き分け・同じ前置きが戻るのは最短 0.35 日')
      # 🔴 **種類別があると共通も毎枠は引かれない**ので、**一周の日数は出さない**（Codex の P2）。
      assert_include(output, '前置きの原稿: 共通 4 本（song・同じ前置きが戻るのは最短 0.65 日')
      assert_not_include(output, '一周 ')
      assert_include(output, '  instrumental / karaoke: song_inst 0 本（⚠ 共通だけ）')
      assert_include(output, '  tv_size / vocal: song_vocal 0 本（⚠ 共通だけ）')
    end

    # ⚠ **種類別だけがあって共通が 0 本でも、「0 本」とは言わない。**
    def test_slot_with_only_kind_prefixes
      add_prefixes(2, type: 'song_bgm')
      output = capture {command.slot}

      assert_include(output, '前置きの原稿: 共通 0 本（song・⚠ 種類別の無い kind は曲だけ）')
      assert_include(output, '  bgm: song_bgm 2 本')
      # 🔴 **共通が 0 本なら、種類別の束は毎枠引かれ、種類別の無い束は曲だけ**（#314）。
      assert_include(output, '  bgm: song_bgm 2 本（毎枠この束・')
      assert_include(output, '  tv_size / vocal: song_vocal 0 本（⚠ 曲だけ）')
      assert_not_include(output, '引き分け')
      assert_not_include(output, '共通だけ')
    end

    # 🔴 **sample はどの束のどの原稿を使ったかを出す**（#314）。⚠⚠ **`--pool=own` で種類別を
    # 確かめられる**（今日の 1 本目が共通を引く日でも）。
    def test_sample_names_the_bundle
      add_prefixes(4)
      add_prefixes(1, type: 'song_bgm')
      own = capture {command(kind: 'bgm', pool: 'own').sample}
      common = capture {command(kind: 'bgm', pool: 'common').sample}

      assert_include(own, 'song_bgm（種類別）')
      assert_include(own, '前置き 0')
      assert_include(common, 'song（共通）')
    end

    # 🔴 **語りの表が読めなければ、下見の頭でそう言う**（#314）。⚠⚠ **理由は syslog にしか出ていなかった。**
    def test_preview_says_the_spoken_table_is_unreadable
      song.define_singleton_method(:spoken_tracks) {raise Ginseng::ValidateError, 'track_spoken.yaml: 壊れている'}
      output = capture {command(date: '2026-09-01', days: 1).preview}

      assert_include(output, '🔴 語りの表を読めません（⚠ 全部の曲を共通だけにします）: track_spoken.yaml: 壊れている')
    end

    # ⚠ **別名表が壊れていても言う**（PR #475 の Codex の P2 — 語りの表は読めても `keys` で落ちる）。
    def test_preview_says_the_alias_table_is_unreadable
      spoken = Object.new
      spoken.define_singleton_method(:names) {['しまうまグルグル']}
      spoken.define_singleton_method(:keys) {raise Ginseng::ValidateError, 'track_aliases.yaml: 壊れている'}
      song.define_singleton_method(:spoken_tracks) {spoken}
      output = capture {command(date: '2026-09-01', days: 1).preview}

      assert_include(output, '🔴 語りの表を読めません（⚠ 全部の曲を共通だけにします）: track_aliases.yaml: 壊れている')
    end

    # ⚠ **種類別を指定して 0 本なら、前置きは無い**（曲だけになる）。
    def test_sample_with_an_empty_own_bundle
      add_prefixes(4)
      output = capture {command(kind: 'bgm', pool: 'own').sample}

      assert_include(output, '（前置きはありません）')
    end

    # ⚠ **下見はどの `kind` の曲に付いたかを出す**（#293・前置きの束が `kind` で決まるため）。
    def test_preview_shows_the_kind
      output = capture {command(date: '2026-09-01', days: 1).preview}

      assert_match(/\A {2}\d{2}:\d{2} .+（(#{song.kind_types.keys.join('|')})）\z/, output.lines[1].chomp)
    end

    # 🔴 **重みが付いているのに 1 曲も無い kind を 0% と出す**（Codex の P2）。
    # ⚠⚠ **この画面はまさに「母集合と設定の食い違い」を見るためのもの**なので、
    # ⚠ **重みだけで割ると、引けない kind が「出る」と表示される。**
    def test_slot_reports_zero_for_a_kind_without_tracks
      output = capture {command.slot}
      line = output.lines.find {|text| text.include?('instrumental')}

      assert_not_nil(line)
      assert_include(line, '0 曲')
      assert_include(line, '0.0%')
      assert_include(line, '曲が 1 曲も無い')
    end

    # ⚠ 曲がある kind は素直に比が出る。
    def test_slot_reports_the_share_of_an_available_kind
      output = capture {command.slot}
      line = output.lines.find {|text| text.include?('vocal')}

      assert_not_include(line, '0.0%')
      assert_not_include(line, '曲が 1 曲も無い')
    end

    # ⚠⚠ **黙る日が 1 画面で見える**（設定を消すと黙らなくなるので）。
    def test_slot_lists_the_quiet_days
      output = capture {command.slot}

      assert_include(output, '黙る日: 11-03 / 11-04')
    end

    def test_slot_says_when_there_is_no_prefix
      output = capture {command.slot}

      assert_include(output, '前置きの原稿: 0 本')
    end
  end
end
