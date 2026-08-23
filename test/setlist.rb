module Makoto
  class SetlistTest < TestCase
    OPENING = 'オープニングの曲'.freeze
    CLOSING = 'クロージングの曲'.freeze

    # ⚠ 実際の cure-api を叩かない。**カバーの母集合はプリキュア歌手に絞られる**ので、
    # テスト用の曲の名義（`歌手NNNN`）を全部「歌手」として通す差し替えを渡す。
    FakeCureApi = Struct.new(:names) do
      def available?
        return true
      end

      def singer?(artist_name)
        return names.nil? || artist_name.to_s.start_with?('歌手')
      end
    end

    # ⚠ **警告を数えるための受け皿**（#88）。⚠⚠ **「黙って 0 件になる」を防ぐのが
    # 目的**なので、**返り値だけ見るテストでは足りない。**
    Recorder = Struct.new(:messages) do
      def warn(payload)
        messages.push(payload[:message].to_s)
      end

      def info(*)
      end

      def error(*)
      end
    end

    # ⚠ 写しを持ち越さない（#88 → `CureApiService`）。
    setup do
      FileUtils.rm_f(CureApiService.cache_path)
    end

    teardown do
      FileUtils.rm_f(CureApiService.cache_path)
    end

    def setup
      super
      @db = empty_db
      config['/live/setlist/opening'] = OPENING
      config['/live/setlist/closing'] = CLOSING
      config['/live/setlist/cover_size'] = 2
    end

    # ⚠ **警告を出すのは `CoverSelector`**（`Setlist` ではない → #88）。
    def selector
      return CoverSelector.new(date: date, repository: repository, cure_api: CureApiService.new)
    end

    def warnings_of(target)
      recorder = Recorder.new([])
      target.instance_variable_set(:@logger, recorder)
      target.exec
      return recorder.messages
    end

    # ⚠ **本物の `CureApiService` で組む。**⚠⚠ **写しの有無で並びが変わらないこと**
    # （#88）は、偽物を渡すと何も見ていない。
    def real_setlist(slots)
      return Setlist.new(date: date, slots: slots, repository: repository,
        cure_api: CureApiService.new)
    end

    # カバー候補（ライブ用に入っていない曲）の名義。
    def cover_artists
      names = @db[:track].where(live: false).select_map(:artist_name).uniq
      return names.map {|name| {'name' => name, 'members' => []}}
    end

    def stub_singers(records)
      stub = stub_request(:get, "#{config['/cure_api/url']}/singers")
      return stub.to_return(status: 200, body: records.to_json,
        headers: {'Content-Type' => 'application/json'})
    end

    def repository
      return TrackRepository.new(@db)
    end

    def date
      return Date.new(2026, 11, 4)
    end

    def cure_api
      return FakeCureApi.new(nil)
    end

    def setlist(slots, **)
      return Setlist.new(date: date, slots: slots, repository: repository,
        cure_api: cure_api, **)
    end

    # ⚠ **フィクスチャの曲データは 2 曲しかない**ので、並びを見るテストはここで作る。
    # 発売日を 1 日ずつずらして、整列の順が一意に決まるようにする。
    DEFAULT_TRACK = {
      live: true,
      kind: 'vocal',
      day: 1,
      url: 'https://example.test/t',
      collection: nil,
    }.freeze

    def add(name, **options)
      values = DEFAULT_TRACK.merge(options)
      @id = (@id || 5000) + 1
      @db[:track].insert(
        id: @id,
        name: name,
        artist_name: "歌手#{@id}",
        collection_name: values[:collection],
        release_date: Date.new(2013, 1, 1) + values[:day],
        url: values[:url],
        kind: values[:kind],
        live: values[:live],
        dedupe_key: TrackImporter.dedupe_key(name),
      )
      return @id
    end

    # 本編 n 曲（アンカー 2 つを含む）と、ライブ用に入っていない曲 m 曲。
    def seed(songs: 8, covers: 6)
      add(OPENING, day: 0)
      (1..(songs - 2)).each {|i| add("本編#{'%02d' % i}", day: i)}
      add(CLOSING, day: songs)
      (1..covers).each {|i| add("他の歌手#{i}", live: false, day: 100 + i)}
    end

    # カバー候補（ライブ用に入っていない曲）を、名義を指定して足す。
    def add_cover(name, artist)
      id = add(name, live: false, day: 200 + ((@id || 5000) % 100))
      @db[:track].where(id: id).update(artist_name: artist)
      return id
    end

    def names(entries)
      return entries.map {|entry| entry.mc? ? "MC#{entry.ordinal}" : entry.track[:name]}
    end

    # ⚠⚠ **アンカーは 3 つ。**開始直後・中盤の再演・最終曲（→ docs/birthday-live.md）。
    def test_anchors_open_hinge_and_close
      seed(songs: 8, covers: 0)
      entries = setlist(9).entries

      assert_equal(OPENING, entries.first.track[:name])
      assert_equal(CLOSING, entries.last.track[:name])
      # 蝶番は開始と同じ曲の再演。⚠ 2 回出るのはこの曲だけ。
      assert_equal(2, names(entries).count(OPENING))
    end

    # ⚠ **`〜SONGBIRD〜` の再演は前半と後半の継ぎ目**。元ネタが前後編の蝶番に置いている。
    def test_hinge_sits_between_the_halves
      seed(songs: 8, covers: 0)
      list = names(setlist(9).entries)

      assert_equal([OPENING, '本編01', '本編02', '本編03', OPENING, '本編04', '本編05',
        '本編06', CLOSING], list)
    end

    # ⚠ **本編は発売日順。**#11 の重み付け抽選とは別軸で、ここは整列であって抽選ではない。
    def test_songs_are_sorted_by_release_date
      seed(songs: 6, covers: 0)

      assert_equal([OPENING, '本編01', '本編02', '本編03', '本編04', CLOSING],
        setlist(7).songs.map {|track| track[:name]})
    end

    # ⚠⚠ **同じ日付・同じ枠数なら何度組んでも同じ並び。**これが崩れると、再起動の
    # たびに曲順が変わって「落ちて戻ってきても位置がずれない」が意味を失う。
    def test_setlist_is_stable
      seed(songs: 8, covers: 6)

      assert_equal(names(setlist(20).entries), names(setlist(20).entries))
    end

    # ⚠ カバーは日付で種を固定する。⚠⚠ **年が変われば別の曲になる**（毎年同じでは
    # ゲストコーナーにならない）。
    def test_covers_change_with_the_year
      seed(songs: 8, covers: 20)
      this_year = Setlist.new(date: date, slots: 20, repository: repository,
        cure_api: cure_api).covers
      next_year = Setlist.new(date: date.next_year, slots: 20, repository: repository,
        cure_api: cure_api).covers

      assert_equal(4, this_year.size)
      assert_not_equal(this_year.map {|t| t[:id]}, next_year.map {|t| t[:id]})
    end

    # ⚠⚠ **ゲストコーナーは連続した塊。**MC で割れると「コーナー」に見えない
    # （実装で一度割れた）。前半・後半に 1 つずつ。
    def test_guest_corner_is_contiguous
      seed(songs: 10, covers: 6)
      entries = setlist(24).entries
      positions = entries.each_index.select {|i| entries[i].cover?}

      assert_equal(4, positions.size)
      # 2 つの塊に分かれ、それぞれ中で連番になっている。
      first, second = positions.each_slice(2).to_a

      assert_equal([first[0] + 1], [first[1]])
      assert_equal([second[0] + 1], [second[1]])
    end

    # ⚠ **カバーはライブ用に入っていない曲だけ。**本編の曲をカバーとして出さない。
    # 🔴 **#177。**⚠⚠ **本人がメンバーのユニット名義の曲は、`live` が立っていなくても
    # 本編で歌う** — ⚠ **収集（`seed`）は名義で集めるので、ユニット名義の曲は
    # `live` に入っていない。**
    def test_a_unit_the_singer_belongs_to_is_a_song_not_a_cover
      seed(songs: 6, covers: 2)
      add_cover('ユニットの曲', 'キュア・カルテット')
      config['/live/setlist/own_units'] = ['キュア・カルテット']

      entries = setlist(12).entries

      assert_includes(names(entries), 'ユニットの曲')
      assert_empty(entries.select(&:cover?).map {|entry| entry.track[:name]}
        .grep('ユニットの曲'))
    end

    # ⚠ **中黒の有無で外れない**（供給元の表記は揃っていない）。
    def test_the_unit_matches_without_the_separator
      seed(songs: 6, covers: 2)
      add_cover('ユニットの曲', 'キュアカルテット')
      config['/live/setlist/own_units'] = ['キュア・カルテット']

      assert_includes(names(setlist(12).entries), 'ユニットの曲')
    end

    # ⚠⚠ **粗い絞り込みが混ぜた他人の曲を本編に入れない。**
    def test_another_singer_stays_a_cover
      seed(songs: 6, covers: 2)
      add_cover('他人の曲', '別のユニット')
      config['/live/setlist/own_units'] = ['キュア・カルテット']

      entries = setlist(12).entries
      song_names = entries.select(&:song?).map {|entry| entry.track[:name]}

      assert_not_includes(song_names, '他人の曲')
    end

    # 🔴 **コーラスは本人の判定に使わない**（2026-08-23・オーナー・#177）。
    # ⚠⚠ **コーラスで参加していても、その曲は本人の曲ではない。**
    def test_a_chorus_credit_does_not_make_it_a_song
      seed(songs: 6, covers: 2)
      add_cover('コーラスで入った曲', '別の歌手/コーラス:キュア・カルテット')
      config['/live/setlist/own_units'] = ['キュア・カルテット']

      entries = setlist(12).entries
      song_names = entries.select(&:song?).map {|entry| entry.track[:name]}

      assert_not_includes(song_names, 'コーラスで入った曲')
    end

    # ⚠ **落とすのはコーラスの区画だけ** — **主名義が本人なら本人の曲。**
    def test_the_main_credit_still_counts_with_a_chorus
      seed(songs: 6, covers: 2)
      add_cover('本人が主名義の曲', 'キュア・カルテット/コーラス:別の歌手')
      config['/live/setlist/own_units'] = ['キュア・カルテット']

      assert_includes(names(setlist(12).entries), '本人が主名義の曲')
    end

    def test_covers_never_come_from_the_live_corpus
      seed(songs: 8, covers: 6)
      live_names = setlist(20).songs.map {|track| track[:name]}

      assert_empty(setlist(20).covers.map {|track| track[:name]} & live_names)
    end

    # ⚠ url が無い曲は紹介の形にならないので母集合から外す（→ TrackRepository#linkable）。
    def test_songs_without_url_are_excluded
      seed(songs: 6, covers: 0)
      add('リンクの無い曲', day: 3, url: nil)

      assert_not_includes(setlist(7).songs.map {|track| track[:name]}, 'リンクの無い曲')
    end

    # ⚠ **枠が余れば MC で埋める。**枠の数ぴったりの項目が返ること。
    def test_fills_the_slots_with_mc
      seed(songs: 8, covers: 0)
      entries = setlist(14).entries

      assert_equal(14, entries.size)
      assert_equal(5, entries.count(&:mc?))
    end

    # ⚠ **MC の番号は通し。**原稿を頭から順に消化するので、前半と後半で振り直さない
    # （→ LiveProgram）。
    def test_mc_ordinals_run_through_both_halves
      seed(songs: 8, covers: 0)
      ordinals = setlist(14).entries.select(&:mc?).map(&:ordinal)

      assert_equal([0, 1, 2, 3, 4], ordinals)
    end

    # ⚠⚠ **MC の番号は 0 から連番。**⚠ カバーの本数だけ番号が飛ぶと、
    # `LiveProgram` の `ordinal %% 原稿数` がずれて**用意した原稿の一部が永久に出ず、
    # 別の一部が 2 回出る**（実測で 4 本が欠番になっていた）。
    def test_mc_ordinals_have_no_gap_when_covers_exist
      seed(songs: 12, covers: 8)
      ordinals = setlist(30).entries.select(&:mc?).map(&:ordinal)

      assert_operator(ordinals.size, :>, 2)
      assert_equal((0...ordinals.size).to_a, ordinals)
    end

    # ⚠⚠ **枠より曲が多ければ本編を削る。アンカーは守る。**8 時間に収まらない量の曲を
    # 集めても、開始・蝶番・最終曲は必ず出る。
    def test_trims_the_body_but_keeps_the_anchors
      seed(songs: 20, covers: 0)
      entries = setlist(7).entries

      assert_operator(entries.size, :<=, 7)
      assert_equal(OPENING, entries.first.track[:name])
      assert_equal(CLOSING, entries.last.track[:name])
      assert_equal(2, names(entries).count(OPENING))
    end

    # ⚠⚠ **アンカーの曲名が引けなければ、その位置を諦める。**黙って別の曲を置くと、
    # 「ライブ名の由来の曲で始まる」という形式そのものが崩れたことに気付けない。
    def test_missing_anchor_is_skipped_not_substituted
      seed(songs: 6, covers: 0)
      config['/live/setlist/opening'] = '存在しない曲'
      entries = setlist(7).entries

      assert_not_equal('存在しない曲', entries.first.track[:name])
      assert_equal(CLOSING, entries.last.track[:name])
      # 再演も置かない（開始が無いのに 2 度歌う曲は無い）。
      assert_empty(names(entries).tally.select {|_, count| count > 1})
    end

    # ⚠ カバーを 0 にしたらゲストコーナーそのものが無くなる。
    def test_cover_size_zero_disables_the_corner
      seed(songs: 8, covers: 6)
      config['/live/setlist/cover_size'] = 0

      assert_empty(setlist(20).entries.select(&:cover?))
    end

    # ⚠ 枠の外を引いたら nil（投稿しない）。
    def test_at_returns_nil_outside_the_program
      seed(songs: 8, covers: 0)
      list = setlist(9)

      assert_nil(list.at(nil))
      assert_nil(list.at(-1))
      assert_nil(list.at(list.size))
    end

    # ⚠⚠ **cure-api が引けなければカバーを置かない。**絞れないまま出すと
    # カラオケレーベルやドラマトラックがゲストコーナーに並ぶ。
    # ⚠ ライブそのものは止めない（MC で埋まる）。
    def test_no_covers_when_cure_api_is_unavailable
      seed(songs: 8, covers: 6)
      unavailable = Struct.new(:x) do
        def available? = false
        def singer?(_) = false
      end
      list = Setlist.new(date: date, slots: 20, repository: repository,
        cure_api: unavailable.new(nil))

      assert_empty(list.covers)
      assert_empty(list.entries.select(&:cover?))
      assert_equal(20, list.entries.size)
    end

    # 🔴 **#88 の完了条件。**⚠⚠ **cure-api を止めた状態で組み直しても、生きている
    # ときと同じ並びになること。**
    #
    # ⚠ **旧実装では並びそのものが変わった** — 実測（実 DB / 11-04）で **covers 8・
    # MC 26 → covers 0・MC 34**、⚠⚠ **同じ枠番号で中身が違う枠が 160 枠中 127 枠。**
    # ⚠ **ライブの最中に再起動が挟まれば、残りの進行が別物になる形**だった。
    def test_setlist_survives_a_cure_api_outage
      seed(songs: 8, covers: 6)
      stub_singers(cover_artists)
      live = real_setlist(20)
      expected = names(live.entries)

      # ⚠ 前提の確認。カバーが 0 件なら、この比較は何も見ていない。
      assert_not_empty(live.covers)

      WebMock.reset!
      stub_request(:get, "#{config['/cure_api/url']}/singers").to_timeout

      assert_equal(expected, names(real_setlist(20).entries))
    end

    # 🔴 **「200 だが 1 件も一致しない」を無言にしない**（#88・#80 の黄 3）。
    # ⚠⚠ **`available?` は真のまま**なので、cure-api の生死を見る警告では拾えない。
    # ⚠ **正規化の規則が変わった・辞書が縮んだ**ときにここへ落ちる。
    def test_no_match_is_reported
      seed(songs: 8, covers: 6)
      stub_singers([{'name' => '誰でもない人', 'members' => []}])

      assert_include(warnings_of(selector), 'no track matched the singer list')
      assert_empty(real_setlist(20).covers)
    end

    # ⚠ 部分充填も黙らない（要求 4 に対して 1 しか置けない、が静かに起きる）。
    #
    # ⚠⚠ **名義は本人以外にする**（#177）— 🔴 **本人名義の曲はカバー母集合から
    # 落ちる**ので、本人名義で組むと「1 曲しか置けない」ではなく「0 曲」になる。
    def test_partial_fill_is_reported
      seed(songs: 8, covers: 0)
      add_cover('たった 1 曲', '共演の歌手')
      stub_singers([{'name' => '共演の歌手', 'members' => []}])

      assert_include(warnings_of(selector), 'fewer covers than requested')
    end

    # ⚠ 辞書に居ない名義の曲はカバーに選ばれない。
    def test_covers_are_limited_to_known_singers
      seed(songs: 8, covers: 0)
      add('カラオケ盤', live: false, day: 200, url: 'https://example.test/k')
      picky = Struct.new(:x) do
        def available? = true
        def singer?(name) = !name.to_s.include?('9')
      end
      list = Setlist.new(date: date, slots: 20, repository: repository,
        cure_api: picky.new(nil))

      assert(list.covers.none? {|track| track[:artist_name].include?('9')})
    end

    # ⚠ アンカーすら置けない枠数は設定の誤り。黙って空の並びを返さない。
    def test_rejects_too_few_slots
      seed(songs: 8, covers: 0)

      assert_raise(Ginseng::ConfigError) {setlist(3)}
    end

    # 🔴 **ゲストコーナーは MC の直後から始まる**（#117）。⚠⚠ **宣言の台本は塊の直前の
    # MC に置く**ので、⚠ **間に曲が挟まると「ここから何曲か」が嘘になる**（実測で 3 曲）。
    def test_the_guest_corner_starts_right_after_an_mc
      seed(songs: 10, covers: 6)
      entries = setlist(24).entries
      starts = entries.each_index.select {|i| entries[i].cover? && !entries[i - 1].cover?}

      assert_equal(2, starts.size)
      starts.each {|i| assert_predicate(entries[i - 1], :mc?, "[#{i}] の直前が MC でない")}
    end

    # ⚠ **塊ごとに、直前の MC の番号を配る**（`mc_hinge` と同じ。組むときにしか分からない）。
    def test_mc_covers_records_the_ordinal_before_each_corner
      seed(songs: 10, covers: 6)
      entries = setlist(24).entries
      starts = entries.each_index.select {|i| entries[i].cover? && !entries[i - 1].cover?}
      expected = starts.map {|i| entries[i - 1].ordinal}

      assert_equal(expected, entries.find(&:mc?).mc_covers)
      # ⚠ すべての MC が同じものを持つ（どの枠から見ても同じ並びであること）。
      assert_equal([expected], entries.select(&:mc?).map(&:mc_covers).uniq)
    end

    # ⚠⚠ **塊の直前に MC が無い日でも、塊の順番は崩さない**（Codex の指摘・PR #133）。
    # 🔴 **詰めると後ろの塊が前の塊の宣言（`/live/mc/cover` の 1 つ目）と対応する。**
    #
    # ⚠ **前半の埋め草をコーナーが使い切ると、前半に MC が 1 本も立たない**（実測）。
    def test_mc_covers_keeps_a_placeholder_for_a_corner_without_an_mc
      seed(songs: 8, covers: 6)
      entries = setlist(16).entries
      starts = entries.each_index.select {|i| entries[i].cover? && !entries[i - 1].cover?}

      assert_equal(2, starts.size)
      # ⚠ 1 つ目は直前が MC でない日。**詰めずに nil を残す。**
      assert_equal([nil, 1], entries.find(&:mc?).mc_covers)
      assert_not_predicate(entries[starts.first - 1], :mc?)
      assert_equal(1, entries[starts.last - 1].ordinal)
    end

    # 🔴 **#140。**⚠⚠ **接頭辞を全部遡ると、隣接していない古い MC を拾う。**
    #
    # ⚠ `corner_position` は**その部に MC が足りなければコーナーを曲の間へ置く**
    # （＝意図的にアンカーしない）ので、⚠⚠ **そこで遠くの MC を拾うと、宣言が
    # コーナーのずっと前に出る**（この並びでは MC #0 とコーナーの間に曲が 3 本ある）。
    def test_mc_covers_ignores_an_mc_that_is_not_adjacent
      seed(songs: 8, covers: 6)
      entries = setlist(15).entries
      starts = entries.each_index.select {|i| entries[i].cover? && !entries[i - 1].cover?}

      assert_equal(2, starts.size)
      # ⚠ どちらの塊も直前が曲。**手前に MC が居ても拾わない。**
      starts.each {|i| assert_not_predicate(entries[i - 1], :mc?, "[#{i}] の直前が MC")}
      assert_operator(entries.count(&:mc?), :>, 0)
      assert_equal([nil, nil], entries.find(&:mc?).mc_covers)
    end

    # ⚠ **番号は必ず「直前の 1 つ」のもの**（#140）。塊の数だけ並び、位置は動かない。
    def test_mc_covers_always_points_at_the_entry_right_before_the_corner
      seed(songs: 10, covers: 6)
      [18, 20, 22, 24, 26].each do |slots|
        entries = setlist(slots).entries
        starts = entries.each_index.select {|i| entries[i].cover? && !entries[i - 1].cover?}
        expected = starts.map {|i| entries[i - 1].mc? ? entries[i - 1].ordinal : nil}

        assert_equal(expected, entries.find(&:mc?).mc_covers, "slots=#{slots}")
      end
    end

    # ⚠ カバーが 1 曲も無い日は空。**「塊が無い」を nil と空で割らない。**
    def test_mc_covers_is_empty_without_corners
      seed(songs: 8, covers: 0)

      assert_equal([], setlist(20).entries.find(&:mc?).mc_covers)
    end

    # ⚠ 本編から外す（#63）。**アルバム単位**。
    def test_excludes_a_collection_from_the_program
      seed(songs: 8, covers: 0)
      add('童謡1', day: 20, collection: '劇のアルバム')
      add('童謡2', day: 21, collection: '劇のアルバム')
      config['/live/setlist/exclude/collections'] = ['劇のアルバム']

      assert_not_includes(names(setlist(20).entries), '童謡1')
      assert_not_includes(names(setlist(20).entries), '童謡2')
    end

    # ⚠ **曲単位**でも外せる。表記の揺れは取り込みと同じ規則で吸収する。
    def test_excludes_a_track_by_name
      seed(songs: 8, covers: 0)
      add('外したい曲[7月]', day: 20)
      config['/live/setlist/exclude/tracks'] = ['外したい曲［７月］']

      assert_not_includes(names(setlist(20).entries), '外したい曲[7月]')
    end

    # ⚠⚠ **外した曲をカバーに流さない。**`live` フラグは「本編に出す曲」であると
    # 同時に **「MAKOTO 本人の曲」の印**でもあり、`pick_covers` は「`live` に無い
    # vocal ＝ 他の歌手の持ち歌」で母集合を作る。⚠ **seed の側で `live` を落として
    # 外すと、本編から消えた本人の曲がそのままカバーとして出てくる**（実データで
    # 8 曲流入するのを確認した）。だから外すのは `Setlist` の側。
    def test_excluded_songs_do_not_leak_into_covers
      seed(songs: 8, covers: 6)
      add('童謡1', day: 20, collection: '劇のアルバム')
      config['/live/setlist/exclude/collections'] = ['劇のアルバム']
      list = setlist(20)

      assert_not_includes(names(list.entries), '童謡1')
      assert_not_includes(list.covers.map {|track| track[:name]}, '童謡1')
    end

    # ⚠⚠ **単独名義を優先して引く**（#65）。MAKOTO は 1 人で歌うので、
    # 本来複数の歌手で歌う曲を 1 人でカバーするのは不自然。
    def test_covers_prefer_solo_credits
      seed(songs: 8, covers: 0)
      # ⚠ 単独 4 曲・2 名義 12 曲。**一様なら単独が 4 曲すべて選ばれる確率は低い。**
      (1..4).each {|i| add_cover("単独#{i}", '歌手A')}
      (1..12).each {|i| add_cover("連名#{i}", "歌手B#{i} & 歌手C#{i}")}
      config['/live/setlist/cover_solo_weight'] = 50
      names = setlist(20).covers.map {|track| track[:name]}

      assert_equal(4, names.size)
      assert_operator(names.count {|name| name.start_with?('単独')}, :>=, 3)
    end

    # ⚠ **排除ではなく寄せる。**重みを掛けても連名の曲が引かれる余地は残す。
    def test_covers_still_include_groups
      seed(songs: 8, covers: 0)
      (1..12).each {|i| add_cover("連名#{i}", "歌手B#{i} & 歌手C#{i}")}
      config['/live/setlist/cover_solo_weight'] = 50

      assert_equal(4, setlist(20).covers.size)
    end

    # ⚠ 1 以下なら一様抽選（＝この機能を切る）。
    def test_solo_weight_can_be_disabled
      seed(songs: 8, covers: 6)
      config['/live/setlist/cover_solo_weight'] = 0
      uniform = setlist(20).covers.map {|track| track[:id]}
      config['/live/setlist/cover_solo_weight'] = 1

      assert_equal(uniform, setlist(20).covers.map {|track| track[:id]})
    end

    # ⚠⚠ **重みを入れても「同じ日付なら同じ並び」を壊さない。**壊すと再起動の
    # たびに曲順が変わる。
    def test_weighted_covers_are_stable
      seed(songs: 8, covers: 0)
      (1..4).each {|i| add_cover("単独#{i}", '歌手A')}
      (1..12).each {|i| add_cover("連名#{i}", "歌手B#{i} & 歌手C#{i}")}
      config['/live/setlist/cover_solo_weight'] = 3

      assert_equal(setlist(20).covers.map {|t| t[:id]}, setlist(20).covers.map {|t| t[:id]})
    end

    # ⚠⚠ **バージョン違いは 1 曲に寄せる**（#118）。⚠ **`dedupe_key` は括弧の中身を
    # 残す**ので、`distinct` を通しても 6 曲並ぶ（実測）。
    def test_version_variants_are_merged
      seed(songs: 8, covers: 0)
      add('版違いの曲', day: 20)
      add('版違いの曲【ひょうげんあそび】', day: 21)
      add('版違いの曲 (『番組』より)', day: 22)
      add('版違いの曲~ロング・バージョン(番組)', day: 23)
      list = names(setlist(30).entries)

      assert_equal(1, list.count {|name| name.start_with?('版違いの曲')})
      assert_includes(list, '版違いの曲')
    end

    # ⚠ **残すのは但し書きの無いもの。**⚠⚠ **アンカーは曲名で引く**ので、
    # 但し書きの付いた版を代表にすると、その日のアンカーが黙って消える。
    def test_representative_prefers_the_plain_name
      seed(songs: 8, covers: 0)
      add('版違いの曲 (ロング・バージョン)', day: 20)
      add('版違いの曲', day: 21)

      assert_equal(['版違いの曲'], setlist(30).songs.map {|t| t[:name]}.grep(/版違い/))
    end

    # ⚠ 但し書きの無いものが無ければ id の小さいほう。**同じ日付なら何度組んでも同じ。**
    def test_representative_falls_back_to_the_smallest_id
      seed(songs: 8, covers: 0)
      first = add('版違いの曲 (ロング・バージョン)', day: 20)
      add('版違いの曲(番組)', day: 21)

      assert_equal([first], setlist(30).songs.map {|t| t[:id]} & [first, @id])
      assert_equal(1, setlist(30).songs.count {|t| t[:name].start_with?('版違いの曲')})
    end

    # 🔴 **アンカーを巻き込まない。**⚠⚠ **開始の曲に版違いがあっても、再演を含めて
    # 2 回置かれる**こと（`opening` が引けないと蝶番ごと消える）。
    def test_anchor_survives_a_version_variant
      seed(songs: 8, covers: 0)
      add("#{OPENING} (ロング・バージョン)", day: 20)
      list = names(setlist(30).entries)

      assert_equal(2, list.count(OPENING))
      assert_not_includes(list, "#{OPENING} (ロング・バージョン)")
    end

    # ⚠⚠ **寄せた曲をカバーに流さない**（#63 と同じ理由）。⚠ **`live` フラグを
    # 触っていないので、カバーの母集合は動かない。**
    def test_merged_versions_do_not_leak_into_covers
      seed(songs: 8, covers: 6)
      add('版違いの曲', day: 20)
      add('版違いの曲(番組)', day: 21)
      list = setlist(20)

      assert_not_includes(names(list.entries), '版違いの曲(番組)')
      assert_not_includes(list.covers.map {|track| track[:name]}, '版違いの曲(番組)')
    end

    # ⚠ **別の曲まで寄せない。**括弧書きを落としても曲名が違えば別のまま。
    def test_different_songs_are_not_merged
      seed(songs: 8, covers: 0)
      add('ねこざかなダンシング', day: 20)
      add('ねこざかな体操', day: 21)
      list = names(setlist(30).entries)

      assert_includes(list, 'ねこざかなダンシング')
      assert_includes(list, 'ねこざかな体操')
    end

    # ⚠ 除外の一覧が空なら何も外さない（既定の挙動を変えない）。
    # ⚠⚠ **これは「キーはあるが空」を見るテスト。**⚠ **キーそのものが無い場合は
    # `test/optional_config.rb` の側**（#77。名前が「無い」を謳っていて素通ししていた）。
    def test_excludes_nothing_when_the_lists_are_empty
      seed(songs: 8, covers: 0)
      add('童謡1', day: 20, collection: '劇のアルバム')
      config['/live/setlist/exclude/collections'] = []
      config['/live/setlist/exclude/tracks'] = []

      assert_includes(names(setlist(20).entries), '童謡1')
    end
  end
end
