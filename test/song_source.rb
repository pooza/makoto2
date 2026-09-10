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

    # その日の枠の列。⚠ **枠の本数と時刻は設定が正本**なので、テストに焼かない。
    def slots(date)
      return song.timetable.times(date)
    end

    # 前置きの原稿を足す。⚠ **季節も日付も持たないので段 5（無指定）に入る。**
    # ⚠ **戻り値は本文の一覧**（`create` は id を返す）。
    def add_prefixes(count, type: nil, label: '前置き')
      return Array.new(count) do |i|
        body = "#{label} #{i}"
        @repository.create(type: type || config['/song/type'], body: body)
        body
      end
    end

    # 1 か月ぶんの枠（⚠ **束ごとの出方を見るのに十分な本数**）。
    def month_of_slots
      return (1..30).flat_map {|day| slots(Date.new(2026, 9, day))}
    end

    # 🔴 **引いただけでは履歴に書かない**（#41）。
    #
    # ⚠⚠ **下見（`makoto song preview`）はここを通る**ので、⚠ **引いた時点で書くと
    # 読むだけのつもりの下見が、次に出る曲を変える。**
    def test_drawing_alone_does_not_touch_the_history
      subject = song
      subject.source.call(jst(9, 1))

      assert_equal(0, subject.history.count)
    end

    # 🔴 **出せたと言われて初めて書く**（→ `PostingJob#notify`）。
    def test_posted_records_the_song_that_went_out
      expected = Song.new(repository: @repository, tracks: @tracks, random: Random.new(20_261_104))
        .lottery.draw
      subject = song
      subject.source.call(jst(9, 1))
      subject.source.posted(jst(9, 1))

      assert_equal([expected[:dedupe_key]], subject.history.recent_keys)
    end

    # ⚠ **枠が食い違えば書かない。**⚠⚠ **`tick` は重なりうる**ので、**`call` と
    # `posted` のあいだに別の枠が割り込むことがある** — 🔴 **1 本書き漏らすほうが、
    # 違う曲を「出した」と覚えるより害が小さい。**
    def test_posted_ignores_a_slot_it_did_not_draw
      subject = song
      subject.source.call(jst(9, 1))
      subject.source.posted(jst(9, 2))

      assert_equal(0, subject.history.count)
      subject.source.posted(jst(9, 1))

      assert_equal(1, subject.history.count)
    end

    # 🔴 **枠が重なっても両方とも残る**（Codex の P2）。
    #
    # ⚠⚠ **`tick` は重なりうる**ので、**12:00 の投稿が飛んでいるあいだに 19:00 の枠が
    # `call` を通りうる**（`PostingJob#claim` は新しい枠を通す）。⚠ **直前の 1 つしか
    # 覚えないと、先に返ってきた 12:00 が 19:00 のぶんを消し、両方とも履歴に残らない。**
    def test_two_slots_in_flight_are_both_recorded
      subject = song
      subject.source.call(jst(9, 1, 12))
      subject.source.call(jst(9, 1, 19))
      subject.source.posted(jst(9, 1, 12))
      subject.source.posted(jst(9, 1, 19))

      assert_equal(2, subject.history.count)
    end

    # ⚠ **同じ枠を 2 回言われても 1 本しか書かない**（`PostingJob#claim` の裏側）。
    def test_posted_records_once
      subject = song
      subject.source.call(jst(9, 1))
      subject.source.posted(jst(9, 1))
      subject.source.posted(jst(9, 1))

      assert_equal(1, subject.history.count)
    end

    # 🔴 **出した曲は次の抽選から外れる**（#41 の完了条件）。
    def test_the_song_that_went_out_is_not_drawn_again
      subject = song
      subject.source.call(jst(9, 1))
      subject.source.posted(jst(9, 1))
      key = subject.history.recent_keys.first

      assert_not_include(
        Array.new(50) {subject.lottery.draw[:dedupe_key]},
        key,
      )
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

    # 🔴 **同じ日の枠どうしが同じ前置きにならない**（#292 で 1 日 3 本）。
    # ⚠⚠ **日付だけで送るとここが揃う。**⚠ **枠は設定から取る**（本数を焼かない）。
    def test_the_slots_of_a_day_differ
      add_prefixes(6)
      prefixes = slots(Date.new(2026, 9, 1)).map {|time| source.prefix(time)}

      assert_equal(3, prefixes.size)
      assert_equal(prefixes.size, prefixes.uniq.size)
    end

    # ⚠ **連日でも続かない**（通し番号が枠ごとに 1 進む）。
    def test_no_repeat_across_consecutive_slots
      add_prefixes(6)
      prefixes = (1..7).flat_map do |day|
        slots(Date.new(2026, 9, day)).map {|time| source.prefix(time)}
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
        slots(Date.new(2026, 9, day)).map {|time| source.prefix(time)}
      end

      assert_equal(bodies.sort, picked.uniq.sort)
    end

    # 🔴 **`kind` の前置きは「共通 ＋ その `kind` の type」から引く**（#293）。
    # ⚠ **共通はどの曲にも合う文なので、種類別を書いた `kind` でも候補に残る。**
    def test_a_kind_draws_from_the_common_and_its_own
      common = add_prefixes(3)
      scores = add_prefixes(3, type: 'song_bgm', label: '劇伴')
      picked = month_of_slots.map {|time| source.prefix(time, kind: 'bgm')}

      assert_empty(picked - common - scores)
      assert(picked.intersect?(scores))
      assert(picked.intersect?(common))
    end

    # ⚠⚠ **他の `kind` の前置きは付かない**（**劇伴の前置きが歌の曲に付かない**）。
    def test_a_kind_never_draws_another_kinds_own
      add_prefixes(3)
      scores = add_prefixes(3, type: 'song_bgm', label: '劇伴')
      picked = month_of_slots.map {|time| source.prefix(time, kind: 'vocal')}

      refute(picked.intersect?(scores))
    end

    # 🔴 **種類別が 0 本なら共通だけ**（**書き分ける前の形より悪くならない**）。
    # ⚠ **書いていない `kind` も共通だけ。**
    def test_falls_back_to_the_common
      common = add_prefixes(3)
      add_prefixes(3, type: 'song_bgm', label: '劇伴')

      ['karaoke', 'nosuch', nil].each do |kind|
        picked = month_of_slots.map {|time| source.prefix(time, kind: kind)}

        assert_empty(picked - common, kind.inspect)
      end
    end

    # 🔴 **本文の前置きは、引いた曲の `kind` の束から来る**（#293）。⚠⚠ **曲を引く前に
    # 前置きを選ぶと、ここが食い違う。**
    def test_compose_matches_the_prefix_to_the_drawn_kind
      add_prefixes(2)
      add_prefixes(2, type: 'song_bgm', label: '劇伴')
      add_prefixes(2, type: 'song_vocal', label: '歌')
      allowed = {'song' => song.kind_types.keys, 'song_bgm' => ['bgm'],
                 'song_vocal' => ['vocal', 'tv_size']}
      entries = month_of_slots.filter_map {|time| source.compose(time)}

      assert_false(entries.empty?)
      entries.each do |entry|
        type = entry[:prefix][:type]

        assert_include(allowed.fetch(type), entry[:track][:kind].to_s, type)
        assert(entry[:text].start_with?(entry[:prefix][:body]))
      end
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
      assert_equal(source.prefix(jst(9, 1, 19)), source(1).prefix(jst(9, 1, 19)))
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

    # 🔴 **ライブが持つ日は黙る**（Codex の P1）。⚠⚠ **11/4 は `live-open` が 12:00 で
    # こちらの 1 本目とまったく同じ時刻**、⚠ **`live` の進行が 12:02〜20:00 なので
    # 2 本目の 19:00 もその中。**🔴 **時刻をずらしても解けない。**
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
        prefixes: SongSource::Prefixes.of(song.selector),
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
