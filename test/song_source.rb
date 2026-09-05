module Makoto
  # 曲紹介の本文（#16）。🔴 **完了条件の「紹介文が `kind` に応じて破綻しない」を
  # ここで見る**（⚠ **各 `kind` のサンプルで確認する**）。
  class SongSourceTest < TestCase
    def setup
      super
      @repository = MessageRepository.new(corpus_db)
      @tracks = TrackRepository.new(track_db)
    end

    def song(seed = 20_261_104)
      return Song.new(repository: @repository, tracks: @tracks, random: Random.new(seed))
    end

    def source(seed = 20_261_104)
      return song(seed).source
    end

    def jst(month, day, hour = 12, year: 2026)
      return Time.new(year, month, day, hour, 0, 0, '+09:00')
    end

    # 前置きの原稿を足す。⚠ **季節も日付も持たないので段 5（無指定）に入る。**
    # ⚠ **戻り値は本文の一覧**（`create` は id を返す）。
    def add_prefixes(count)
      return Array.new(count) do |i|
        body = "前置き #{i}"
        @repository.create(type: config['/song/type'], body: body)
        body
      end
    end

    # ⚠⚠ **前置きが 0 件でも壊れない。**🔴 **原稿を書く前から機能として成立する**
    # （**曲だけを出す**）。
    def test_without_a_prefix_the_song_stands_alone
      text = source.call(jst(9, 1))

      assert_not_nil(text)
      assert_equal('♪', text.lines.first[0])
      assert_not_include(text, "\n\n")
    end

    # ⚠ **本文の最後は URL**（→ プレビューカードは SNS 側の機能）。
    def test_the_last_line_is_the_url
      assert_match(%r{\Ahttps://example\.test/track/}, source.call(jst(9, 1)).lines.last.chomp)
    end

    # ⚠⚠ **断りの後ろは 1 行アキ**（#122・`TrackPresenter` と同じ形）。
    def test_the_prefix_is_followed_by_a_blank_line
      add_prefixes(4)
      lines = source.call(jst(9, 1)).lines.map(&:chomp)

      assert_match(/\A前置き \d\z/, lines.first)
      assert_equal('', lines[1])
      assert_equal('♪', lines[2][0])
    end

    # 🔴 **同じ日の 2 本が同じ前置きにならない**（#16 の枠は 1 日 2 本）。
    # ⚠⚠ **日付だけで送るとここが揃う。**
    def test_the_two_slots_of_a_day_differ
      add_prefixes(6)

      assert_not_equal(source.prefix(jst(9, 1, 12)), source.prefix(jst(9, 1, 20)))
    end

    # ⚠ **連日でも続かない**（通し番号が枠ごとに 1 進む）。
    def test_no_repeat_across_consecutive_slots
      add_prefixes(6)
      prefixes = (1..7).flat_map do |day|
        [source.prefix(jst(9, day, 12)), source.prefix(jst(9, day, 19))]
      end

      assert_equal([], prefixes.each_cons(2).select {|a, b| a == b})
    end

    # ⚠⚠ **出ない前置きを作らない。**
    #
    # 🔴 **2 周ぶんの窓で見る**（⚠ **どの日から数え始めても、必ず 1 周まるごとが
    # 入る**）。⚠⚠ **「連続する 6 枠で全件」にはならない** — **周の境目は通し番号で
    # 決まるので、任意の日から 6 枠を切ると 2 つの周にまたがる**（規則そのものは
    # `RotationTest#test_one_cycle_covers_every_record` が見る）。
    def test_every_prefix_comes_up
      bodies = add_prefixes(6)
      picked = (1..6).flat_map do |day|
        [source.prefix(jst(9, day, 12)), source.prefix(jst(9, day, 19))]
      end

      assert_equal(bodies.sort, picked.uniq.sort)
    end

    # 🔴 **同じ枠なら何度呼んでも同じ前置き**（状態を持たない）。⚠ **落ちて戻って
    # きても・別の箱で下見しても同じ**（→ docs/CLAUDE.md）。
    def test_the_same_slot_gives_the_same_prefix
      add_prefixes(5)

      assert_equal(source.prefix(jst(9, 1, 12)), source(1).prefix(jst(9, 1, 12)))
    end

    # ⚠ **枠の外では何も返さない**（枠の番号が出ない）。
    #
    # ⚠⚠ **「枠の外」は 12:00〜19:01 の外**であって、**枠の頭の外ではない**
    # （`Timetable#index_at` は幅で答える）。🔴 **枠の頭かどうかを見るのは
    # `PostingJob#due_slot`** — ⚠ **こちらは呼ばれた時刻がどの枠に属するかだけを見る。**
    def test_outside_the_slots_nothing_is_posted
      assert_nil(source.call(jst(9, 1, 9)))
      assert_nil(source.prefix(jst(9, 1, 21)))
    end

    # ⚠ **枠の中なら、頭でなくてもその枠の前置きになる**（上記の帰結）。
    def test_a_time_inside_the_slot_belongs_to_that_slot
      add_prefixes(6)

      assert_equal(source.prefix(jst(9, 1, 12)), source.prefix(jst(9, 1, 15)))
      assert_equal(source.prefix(jst(9, 1, 20)), source(1).prefix(jst(9, 1, 20)))
    end

    # 🔴 **劇伴はアルバム名を主役にする**（#16）。⚠⚠ **`bgm` の名義は作曲家**なので、
    # ⚠ **どのシリーズの曲かはアルバム名にしか書いていない。**
    def test_the_soundtrack_shows_its_album
      track = @tracks.dataset.first(kind: 'bgm')
      lines = source.presenter(track).to_s.lines.map(&:chomp)

      assert_equal("♪ #{track[:name]}", lines[0])
      assert_equal(track[:collection_name], lines[1])
      assert_equal(track[:artist_name], lines[2])
    end

    # ⚠ **歌はアルバム名を出さない**（名義が歌手そのものなので文脈が足りている）。
    def test_the_vocal_track_does_not_show_its_album
      track = @tracks.dataset.first(kind: 'vocal')

      assert_not_include(source.presenter(track).to_s, track[:collection_name])
    end

    # ⚠⚠ **設定を消せばどの kind でも出さない**（#77）。
    def test_the_album_line_can_be_turned_off
      config['/song/collection_kinds'] = []
      track = @tracks.dataset.first(kind: 'bgm')

      assert_not_include(song.source.presenter(track).to_s, track[:collection_name])
    end

    # 🔴 **括弧書きは落とさない**（#119）。⚠⚠ **`(オリジナル・カラオケ)` `(TVサイズ)` は、
    # その行が何なのかを言っている唯一の手掛かり** — ⚠ **ライブは落とすが日常は残す。**
    def test_the_brackets_survive
      track = @tracks.dataset.first(kind: 'karaoke', id: 1007)

      assert_include(source.presenter(track).to_s, '(オリジナル・カラオケ)')
    end

    # ⚠ **名義は出す**（#121）。⚠⚠ **ライブは自分名義を隠すが、日常はどの歌手の曲かが情報。**
    def test_the_credit_is_shown
      track = @tracks.dataset.first(kind: 'vocal')

      assert_include(source.presenter(track).to_s, track[:artist_name])
    end

    # 🔴 **#16 の完了条件そのもの。**⚠⚠ **母集合に居るすべての `kind` で本文が組める
    # こと**（⚠ **行が欠けない・空行が挟まらない・URL で終わる**）。
    def test_every_kind_builds_a_sound_text
      kinds = @tracks.count_by_kind(song.lottery.candidates).keys

      assert_not_empty(kinds)
      kinds.each do |kind|
        track = song.lottery.candidates.first(kind: kind)
        text = source.presenter(track, '前置き').to_s

        assert_equal(['前置き', ''], text.lines.first(2).map(&:chomp), kind)
        assert_equal(track[:url], text.lines.last.chomp, kind)
        assert_not_include(text.lines[2..].join, "\n\n", kind)
      end
    end

    # 🔴 **ライブが持つ日は黙る**（Codex の P1）。⚠⚠ **11/4 は `live-open` が 12:00・
    # `live-close` が 20:00 で、こちらとまったく同じ時刻。**
    def test_silent_on_the_live_day
      assert_true(source.quiet?(jst(11, 4, 12)))
      assert_nil(source.call(jst(11, 4, 12)))
      assert_nil(source.call(jst(11, 4, 19)))
    end

    # ⚠ **前日増量の日も黙る**（`live-eve` が 12:00〜20:00 の毎正時）。
    def test_silent_on_the_eve
      assert_true(source.quiet?(jst(11, 3, 12)))
      assert_nil(source.call(jst(11, 3, 19)))
    end

    # ⚠⚠ **予告だけの日は黙らない**（10:00 なのでぶつからない）。
    # 🔴 **黙るのは「ライブの枠が持つ日」だけ**で、記念日そのものではない。
    def test_the_announcement_days_still_get_a_song
      assert_false(source.quiet?(jst(11, 1, 12)))
      assert_not_nil(source.call(jst(11, 1, 12)))
      assert_not_nil(source.call(jst(11, 2, 19)))
    end

    def test_an_ordinary_day_is_not_quiet
      assert_false(source.quiet?(jst(9, 1, 12)))
    end

    # ⚠ **設定を消せば黙らない**（#77）。⚠⚠ **ただし消すのは枠をライブの外へ
    # 動かしたときだけ。**
    def test_the_gate_can_be_emptied
      config['/song/quiet_types'] = []

      assert_false(song.source.quiet?(jst(11, 4, 12)))
      assert_not_nil(song.source.call(jst(11, 4, 12)))
    end

    # 🔴 **見るのは許可リストで絞る前の予約**（⚠⚠ **`anniversary_types_on` は自分の
    # type（`song`）で絞るので、ライブの予約が 1 件も見えない**）。
    def test_the_gate_looks_past_its_own_allow_list
      assert_empty(song.selector.anniversary_types_on(Date.new(2026, 11, 4)))
      assert_include(song.selector.reserved_types_on(Date.new(2026, 11, 4)), 'live_open')
    end

    # 🔴 **引けなかったら黙らない。**⚠⚠ **`PostingJob` は「本文が無い」を `debug` に
    # しか書かない** — ⚠ **曲紹介は毎日出る枠**なので、**引けないのは異常。**
    def test_an_empty_pool_leaves_a_warning
      subject = SongSource.new(
        lottery: EmptyLottery.new,
        selector: song.selector,
        timetable: song.timetable,
      )
      logged = []
      subject.define_singleton_method(:logger) {Recorder.new(logged)}

      assert_nil(subject.call(jst(9, 1)))
      assert_equal([{post: 'song', message: 'no track to introduce'}], logged)
    end

    # 曲を 1 つも持たない抽選。⚠ **母集合が空**（設定の誤りは `TrackLottery` が例外）。
    class EmptyLottery
      def draw(_records = nil)
        return nil
      end
    end

    # ⚠ **警告が出たことだけを見る**（ログの置き場と書式には依存しない）。
    class Recorder
      def initialize(logged)
        @logged = logged
      end

      def warn(payload)
        return @logged.push(payload)
      end
    end
  end
end
