module Makoto
  class SetlistTest < TestCase
    OPENING = 'オープニングの曲'.freeze
    CLOSING = 'クロージングの曲'.freeze

    def setup
      super
      @db = empty_db
      config['/live/setlist/opening'] = OPENING
      config['/live/setlist/closing'] = CLOSING
      config['/live/setlist/cover_size'] = 2
    end

    def repository
      return TrackRepository.new(@db)
    end

    def date
      return Date.new(2026, 11, 4)
    end

    def setlist(slots, **)
      return Setlist.new(date: date, slots: slots, repository: repository, **)
    end

    # ⚠ **フィクスチャの曲データは 2 曲しかない**ので、並びを見るテストはここで作る。
    # 発売日を 1 日ずつずらして、整列の順が一意に決まるようにする。
    def add(name, live: true, kind: 'vocal', day: 1, url: 'https://example.test/t')
      @id = (@id || 5000) + 1
      @db[:track].insert(
        id: @id,
        name: name,
        artist_name: "歌手#{@id}",
        release_date: Date.new(2013, 1, 1) + day,
        url: url,
        kind: kind,
        live: live,
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
      this_year = Setlist.new(date: date, slots: 20, repository: repository).covers
      next_year = Setlist.new(date: date.next_year, slots: 20, repository: repository).covers

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

    # ⚠ アンカーすら置けない枠数は設定の誤り。黙って空の並びを返さない。
    def test_rejects_too_few_slots
      seed(songs: 8, covers: 0)

      assert_raise(Ginseng::ConfigError) {setlist(3)}
    end
  end
end
