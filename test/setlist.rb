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

    # ⚠ 設定が無ければ何も外さない（既定の挙動を変えない）。
    def test_excludes_nothing_without_the_setting
      seed(songs: 8, covers: 0)
      add('童謡1', day: 20, collection: '劇のアルバム')
      config['/live/setlist/exclude/collections'] = []
      config['/live/setlist/exclude/tracks'] = []

      assert_includes(names(setlist(20).entries), '童謡1')
    end
  end
end
