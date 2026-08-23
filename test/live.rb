module Makoto
  class LiveTest < TestCase
    def setup
      super
      @messages = MessageRepository.new(corpus_db)
      @tracks = TrackRepository.new(corpus_db)
      seed_tracks
    end

    def live
      return Live.new(repository: @messages, tracks: @tracks)
    end

    def jst(month, day, hour = 12, minute = 0, year: 2026)
      return Time.new(year, month, day, hour, minute, 0, '+09:00')
    end

    # ⚠ フィクスチャの曲は 2 曲しかないので、8 時間の並びを見るぶんだけ足す。
    def seed_tracks
      config['/live/setlist/opening'] = 'ライブの 1 曲目'
      config['/live/setlist/closing'] = 'ライブの最終曲'
      config['/live/setlist/cover_size'] = 0
      ['ライブの 1 曲目', '本編A', '本編B', '本編C', 'ライブの最終曲'].each_with_index do |name, i|
        corpus_db[:track].insert(
          id: 7000 + i, name: name, artist_name: "歌手#{i}",
          release_date: Date.new(2013, 1, 1) + i, url: "https://example.test/t/#{i}",
          kind: 'vocal', live: true, dedupe_key: TrackImporter.dedupe_key(name)
        )
      end
    end

    def add(type, body, month: 11, day: 4, year: 2026)
      return @messages.create(type: type, body: body, year: year, month: month, day: day)
    end

    def job_source(job)
      return job.send(:instance_variable_get, :@source)
    end

    # ⚠ 台本の代わり。`script_index` は本文を見ないので slug だけあればよい。
    def fake_scripts(size)
      return Array.new(size) {|i| {slug: "s#{i}", body: "MC #{i}"}}
    end

    # MC の枠の頭の時刻。⚠ 並びの中の位置と時刻を突き合わせるのに使う。
    def mc_times(list, date = Date.new(2026, 11, 4))
      times = live.timetable.times(date)
      return list.entries.each_index.select {|i| list.at(i).mc?}.map {|i| times[i]}
    end

    # ⚠⚠ **ライブの 4 枠すべてにハッシュタグが付く**（#64）。⚠ 曲の投稿は原稿では
    # ないので、原稿の側に書き足す形にすると**曲だけ付かない。**
    def test_every_slot_appends_the_hashtag
      add('live_eve', '明日はバースデーライブです', day: 3)
      add('live_open', 'スタートです')
      add('live_close', 'おしまいです')
      tag = config['/live/hashtag']

      assert_equal(
        [true, true, true, true],
        [
          job_source(live.eve_job).call(jst(11, 3, 13, 0)),
          job_source(live.open_job).call(jst(11, 4, 12, 0)),
          # ⚠ 曲の枠。`TrackPresenter` の出力（URL の後ろ）に付くこと。
          job_source(live.program_job).call(jst(11, 4, 12, 2)),
          job_source(live.close_job).call(jst(11, 4, 20, 0)),
        ].map {|text| text.to_s.lines.last == tag},
      )
    end

    # ⚠⚠ **本文が無い枠にタグだけ出さない。**nil は「その枠は投稿しない」の合図で、
    # ⚠ ここでタグを足すと**タグだけの投稿が毎日出る。**
    def test_hashtag_is_not_posted_alone
      assert_nil(job_source(live.open_job).call(jst(6, 15, 12, 0)))
      assert_nil(job_source(live.program_job).call(jst(6, 15, 13, 0)))
    end

    # ⚠ 枠は 4 つ。**前日増量・開始告知・8 時間の進行・終了告知。**
    def test_registers_four_jobs
      assert_equal(['live-eve', 'live-open', 'live', 'live-close'], live.jobs.map(&:name))
    end

    # ⚠ **12:00 と 20:00 は告知の枠。**曲は 12:02 から始まり 20:00 を含まない
    # （含めると告知と曲が同じ時刻に重なる）。
    def test_announcements_do_not_collide_with_songs
      assert_equal([jst(11, 4, 12, 0)], live.timetable('open').times(Date.new(2026, 11, 4)))
      assert_equal([jst(11, 4, 20, 0)], live.timetable('close').times(Date.new(2026, 11, 4)))
      songs = live.timetable.times(Date.new(2026, 11, 4))

      assert_equal(jst(11, 4, 12, 2), songs.first)
      assert_equal(jst(11, 4, 19, 59), songs.last)
    end

    # ⚠ 冪等キーは枠の頭から作る。再起動で同じ枠を処理しても Mastodon が畳む。
    def test_idempotency_key_comes_from_the_slot
      assert_equal('live-20261104T030200Z', live.program_job.idempotency_key(jst(11, 4, 12, 2)))
    end

    # ⚠⚠ **ライブ当日は曲が出る。**開始直後は 1 曲目（ライブ名の由来の曲）。
    def test_program_plays_the_opening_song_first
      assert_includes(live.program.call(jst(11, 4, 12, 2)), 'ライブの 1 曲目')
    end

    # ⚠⚠⚠ **ライブ当日以外は 1 本も出さない。**告知や MC は「その日の原稿が無ければ
    # 出ない」で黙るが、⚠ **曲は原稿ではないので黙らせるものが無い。**これが抜けると
    # 毎日 12:02〜20:00 に 8 時間ぶんの曲が流れる。
    def test_program_is_silent_on_every_other_day
      times = [jst(1, 1, 12, 2), jst(6, 15, 15, 2), jst(11, 1, 12, 2), jst(11, 3, 12, 2),
        jst(11, 5, 12, 2), jst(12, 24, 18, 2)]

      assert_empty(times.filter_map {|time| live.program.call(time)})
    end

    # 警告を拾う入れ物。⚠ **実サーバーにも syslog にも書かない。**
    def with_recorder(program)
      recorder = []
      program.instance_variable_set(:@logger, Struct.new(:x) do
        define_method(:warn) {|payload| recorder.push(payload[:message].to_s)}
        define_method(:info) {|payload| payload}
        define_method(:debug) {|payload| payload}
        def error(*)
        end
      end.new(nil))
      yield
      return recorder
    end

    # 🔴 **#80 の黄 9 の本体。**⚠⚠ **平常日の空回りと「ライブが壊れて何も出ない」が、
    # ログ上でまったく同じだった**（どちらも `no text` の 1 行）。⚠ **11/4 に 160 枠が
    # 全滅しても、平常日のログと 1 文字も変わらない。**
    #
    # ⚠ **ここまで来ているということは「ライブ当日で、枠の中」**なので、⚠⚠ **本文が
    # 無いのは原稿が無いのではなく壊れている。**
    def test_a_silent_slot_on_the_live_day_is_reported
      program = live.program
      time = mc_times(program.setlist(jst(11, 4, 13, 0))).first
      recorder = with_recorder(program) do
        assert_nil(program.call(time))
      end

      assert_include(recorder, 'no text for the slot')
    end

    # ⚠⚠ **平常日は黙る。**⚠ **枠は毎日空回りする設計**なので、ここで警告を出すと
    # **8/15〜10/31 の 2 か月半が延々と黄色になる**（#78 で「本文が無い」を中立に
    # 置いたのと同じ判断）。
    def test_a_silent_slot_on_an_ordinary_day_is_not_reported
      program = live.program
      recorder = with_recorder(program) do
        assert_nil(program.call(jst(6, 15, 15, 2)))
      end

      assert_empty(recorder)
    end

    # ⚠ 枠の外でも黙る（告知の時刻・ライブが終わったあと）。
    def test_a_slot_outside_the_live_is_not_reported
      program = live.program
      recorder = with_recorder(program) do
        assert_nil(program.call(jst(11, 4, 23, 0)))
      end

      assert_empty(recorder)
    end

    # ⚠ 枠の外（12:00 の告知の時刻・20:00 以降）では曲を返さない。
    def test_program_is_silent_outside_the_slot
      assert_nil(live.program.call(jst(11, 4, 12, 0)))
      assert_nil(live.program.call(jst(11, 4, 20, 0)))
      assert_nil(live.program.call(jst(11, 4, 23, 0)))
    end

    # ⚠⚠ **MC は原稿を台本の順に消化する。**乱択だと同じ原稿が何度も出て、出ない
    # 原稿が残る。⚠ **枠のほうが多ければ同じ原稿が続くが、巻き戻らない。**
    def test_mc_follows_the_script_order
      add('live_mc', 'MC その 1')
      add('live_mc', 'MC その 2')
      program = live.program
      list = program.setlist(jst(11, 4, 13, 0))
      texts = mc_times(list).map {|time| program.call(time)}

      assert_operator(texts.size, :>=, 3)
      assert_equal('MC その 1', texts.first)
      assert_equal('MC その 2', texts.last)
      assert_equal(texts, texts.sort)
    end

    # ⚠⚠ **台本は位置で意味が決まる**（#69）。`最後の1曲。` は最後でなければ嘘になる。
    # ⚠ **枠が原稿より多くても、最初の枠は 1 本目・最後の枠は最後の 1 本。**
    # ⚠⚠ **これが `ordinal % 原稿数` では成立しない**（`最後の1曲。` が中盤に出た）。
    def test_mc_keeps_the_script_arc_when_slots_outnumber_scripts
      3.times {|i| add('live_mc', "MC #{i}")}
      program = live.program
      list = program.setlist(jst(11, 4, 13, 0))
      entries = list.entries.select(&:mc?)
      texts = entries.map {|entry| program.mc_text(entry, jst(11, 4, 13, 0))}

      assert_operator(entries.size, :>, 3)
      assert_equal('MC 0', texts.first)
      assert_equal('MC 2', texts.last)
      # ⚠ 巻き戻らない＝一度進んだら戻らない。
      assert_equal(texts, texts.sort)
    end

    # ⚠ **原稿を足しても引いても、端の 2 つは動かない。**⚠⚠ **本数と枠数を独立させる**
    # のがこの規則の要点で、曲数が動けば MC の枠数も動く（#63 で 17 → 25 枠になった）。
    def test_mc_arc_survives_a_different_script_count
      8.times {|i| add('live_mc', 'MC %02d' % i)}
      program = live.program
      time = jst(11, 4, 13, 0)
      entries = program.setlist(time).entries.select(&:mc?)
      texts = entries.map {|entry| program.mc_text(entry, time)}

      assert_equal('MC 00', texts.first)
      assert_equal('MC 07', texts.last)
      assert_equal(texts, texts.sort)
    end

    # ⚠⚠ **原稿のほうが多い日でも、最後の枠は最後の 1 本**（#71 のレビュー指摘）。
    # ⚠ `ordinal × 原稿数 ÷ 枠数` だと 25 本 24 枠で 24 番目が永久に出ない。
    # ⚠⚠ **`最後の1曲。` が出ないという、#69 が消そうとした壊れ方そのもの。**
    def test_script_index_matches_both_ends
      program = live.program
      [[24, 25], [24, 17], [25, 25], [23, 25], [2, 25]].each do |slots, size|
        first = Setlist::Entry.new(kind: :mc, ordinal: 0, mc_total: slots)
        last = Setlist::Entry.new(kind: :mc, ordinal: slots - 1, mc_total: slots)

        assert_equal(0, program.script_index(first, fake_scripts(size)), "#{slots} 枠 / #{size} 本")
        assert_equal(size - 1, program.script_index(last, fake_scripts(size)),
          "#{slots} 枠 / #{size} 本")
      end
    end

    # ⚠ 枠が 1 つしか無い日は、両端に合わせようがない。**台本の頭を出す**
    # （`最後の1曲。` を単独で出すより、始まりの 1 本のほうが破綻しない）。
    def test_a_single_mc_slot_uses_the_first_script
      entry = Setlist::Entry.new(kind: :mc, ordinal: 0, mc_total: 1)

      assert_equal(0, live.program.script_index(entry, fake_scripts(25)))
    end

    # ⚠ 総数が分からない項目（`Setlist` 以外が作ったもの）は従来どおり巻き戻す。
    def test_script_index_falls_back_without_a_total
      entry = Setlist::Entry.new(kind: :mc, ordinal: 5)

      assert_equal(2, live.program.script_index(entry, fake_scripts(3)))
    end

    # ⚠⚠ **中間アンカーは蝶番の直後に来る**（#73）。⚠ **両端だけでは足りない** —
    # 台本は「MC の何番目か」、蝶番は「曲の何番目か」で位置が決まるので、
    # ⚠⚠ **曲数が 1 曲動くだけで `後半。` が蝶番の前に出る**（#58 で実際に起きた）。
    def test_the_hinge_script_lands_right_after_the_hinge
      program = live.program
      config['/live/mc/hinge'] = 's12'
      # ⚠ 枠数を変えても、蝶番の MC には必ず `s12` が来ること。
      [[26, 13], [24, 12], [30, 15], [20, 10]].each do |slots, hinge|
        entry = Setlist::Entry.new(kind: :mc, ordinal: hinge, mc_total: slots, mc_hinge: hinge)

        assert_equal(12, program.script_index(entry, fake_scripts(25)), "#{slots} 枠 / 蝶番 #{hinge}")
      end
    end

    # ⚠ 中間アンカーを名指ししても、両端は動かない。
    def test_the_hinge_script_does_not_move_the_ends
      program = live.program
      config['/live/mc/hinge'] = 's12'
      first = Setlist::Entry.new(kind: :mc, ordinal: 0, mc_total: 26, mc_hinge: 13)
      last = Setlist::Entry.new(kind: :mc, ordinal: 25, mc_total: 26, mc_hinge: 13)

      assert_equal(0, program.script_index(first, fake_scripts(25)))
      assert_equal(24, program.script_index(last, fake_scripts(25)))
    end

    # ⚠⚠ **名指しした台本が引けなければ、落ちずに通常の割合で引く**
    # （`Setlist` のアンカーと同じ判断 — 引けなければ黙って別のものを置かない）。
    def test_a_missing_hinge_script_falls_back_to_the_straight_line
      program = live.program
      config['/live/mc/hinge'] = '存在しない slug'
      entry = Setlist::Entry.new(kind: :mc, ordinal: 13, mc_total: 26, mc_hinge: 13)

      assert_equal(13, program.script_index(entry, fake_scripts(26)))
    end

    # ⚠⚠ **名指しの台本は蝶番より前に出ない**（#76 のレビュー指摘）。
    # ⚠ **継ぎ目を前半の終端にすると、丸めで蝶番の 1 つ手前にも出て 2 回言う**
    # （`mc_hinge = 13` / 継ぎ目 5 なら `12 × 5 ÷ 13 = 4.6` が 5 に丸まる）。
    def test_the_hinge_script_never_appears_before_the_hinge
      program = live.program
      config['/live/mc/hinge'] = 's5'
      scripts = fake_scripts(25)
      indexes = Array.new(26) do |ordinal|
        entry = Setlist::Entry.new(kind: :mc, ordinal: ordinal, mc_total: 26, mc_hinge: 13)
        program.script_index(entry, scripts)
      end

      assert_equal(5, indexes[13])
      assert_equal(13, indexes.index(5))
      assert_empty(indexes.first(13).select {|index| index >= 5})
    end

    # 🔴 **カバー宣言の台本は、ゲストコーナーの塊の直前の MC に来る**（#117）。
    # ⚠⚠ **塊の位置は曲と MC を並べた配列の位置、台本の位置は「MC の何番目か」**で
    # 決まるので、⚠ **繋がないと曲数が動くたびにずれる**（実測で 3 曲）。
    def test_the_cover_script_lands_right_before_the_corner
      program = live.program
      config['/live/mc/cover'] = ['s7', 's20']
      expected = [7, 20]
      # ⚠ 枠数を変えても、宣言の MC には必ずその台本が来ること。
      [[48, [14, 39]], [26, [8, 21]], [60, [18, 48]]].each do |slots, covers|
        covers.each_with_index do |ordinal, index|
          entry = Setlist::Entry.new(kind: :mc, ordinal: ordinal, mc_total: slots,
            mc_hinge: nil, mc_covers: covers)

          assert_equal(expected[index], program.script_index(entry, fake_scripts(26)),
            "#{slots} 枠 / 宣言 #{ordinal}")
        end
      end
    end

    # ⚠⚠ **継ぎ目は 3 つ同時に立つ**（前半の宣言・蝶番・後半の宣言）。
    # ⚠ **どれも自分の MC にぴったり来て、並びは巻き戻らない。**
    def test_three_anchors_all_land
      program = live.program
      config['/live/mc/hinge'] = 's13'
      config['/live/mc/cover'] = ['s7', 's20']
      scripts = fake_scripts(26)
      indexes = Array.new(48) do |ordinal|
        entry = Setlist::Entry.new(kind: :mc, ordinal: ordinal, mc_total: 48,
          mc_hinge: 24, mc_covers: [14, 39])
        program.script_index(entry, scripts)
      end

      assert_equal([7, 13, 20], [indexes[14], indexes[24], indexes[39]])
      # ⚠ **名指しの台本は自分の継ぎ目より前に出ない**（#76 と同じ規則）。
      assert_equal([14, 24, 39], [indexes.index(7), indexes.index(13), indexes.index(20)])
      assert_equal(indexes, indexes.sort)
      assert_equal([0, 25], [indexes.first, indexes.last])
    end

    # ⚠ 引けない slug は継ぎ目にしない。**残りの継ぎ目は生きる。**
    def test_a_missing_cover_script_keeps_the_other_anchors
      program = live.program
      config['/live/mc/hinge'] = 's13'
      config['/live/mc/cover'] = ['存在しない slug', 's20']
      entry = lambda do |ordinal|
        Setlist::Entry.new(kind: :mc, ordinal: ordinal, mc_total: 48,
          mc_hinge: 24, mc_covers: [14, 39])
      end

      assert_equal(13, program.script_index(entry.call(24), fake_scripts(26)))
      assert_equal(20, program.script_index(entry.call(39), fake_scripts(26)))
    end

    # ⚠⚠ **直前に MC が無い塊は `nil` で場所を空けてある**（Codex の指摘・PR #133）。
    # 🔴 **2 つ目の塊が 1 つ目の宣言と対応してはいけない。**
    def test_a_corner_without_an_mc_does_not_shift_the_declarations
      program = live.program
      config['/live/mc/cover'] = ['s7', 's20']
      entry = Setlist::Entry.new(kind: :mc, ordinal: 39, mc_total: 48, mc_covers: [nil, 39])

      assert_equal(20, program.script_index(entry, fake_scripts(26)))
    end

    # ⚠⚠ **前へ進まない継ぎ目は捨てる。**⚠ **残すと台本が巻き戻る** — 台本の並びと
    # 塊の並びが食い違った日（宣言の slug を入れ替えてしまった等）の保険。
    def test_anchors_that_go_backwards_are_dropped
      program = live.program
      config['/live/mc/hinge'] = 's13'
      # ⚠ 後半の宣言（MC 39）に、前半より前の台本（s3）を指してしまった状態。
      config['/live/mc/cover'] = ['s7', 's3']
      scripts = fake_scripts(26)
      indexes = Array.new(48) do |ordinal|
        entry = Setlist::Entry.new(kind: :mc, ordinal: ordinal, mc_total: 48,
          mc_hinge: 24, mc_covers: [14, 39])
        program.script_index(entry, scripts)
      end

      assert_equal(indexes, indexes.sort)
      assert_equal([7, 13], [indexes[14], indexes[24]])
    end

    # ⚠ カバーの塊が無い日（`mc_covers` が空）は蝶番だけで割る。
    def test_without_corners_only_the_hinge_splits
      program = live.program
      config['/live/mc/hinge'] = 's12'
      config['/live/mc/cover'] = ['s7']
      entry = Setlist::Entry.new(kind: :mc, ordinal: 13, mc_total: 26, mc_hinge: 13,
        mc_covers: [])

      assert_equal(12, program.script_index(entry, fake_scripts(25)))
    end

    # ⚠ 台本の順序は蝶番をまたいでも巻き戻らない。
    def test_the_hinge_split_stays_monotonic
      program = live.program
      config['/live/mc/hinge'] = 's12'
      indexes = Array.new(26) do |ordinal|
        entry = Setlist::Entry.new(kind: :mc, ordinal: ordinal, mc_total: 26, mc_hinge: 13)
        program.script_index(entry, fake_scripts(25))
      end

      assert_equal(indexes, indexes.sort)
      assert_equal(12, indexes[13])
    end

    # ⚠ 名義だけを差し替えた 1 行。**投稿の見え方（#119 / #121）を見るのに使う。**
    def track_row(artist, name: '曲名')
      return {name: name, artist_name: artist, url: 'https://example.test/t/9'}
    end

    # 🔴 **ライブの本編では自分名義を出さない**（#121）。**歌っているのが自分であることが
    # 自明**なので、名義がノイズになる。
    def test_own_credit_is_hidden_in_the_program
      entry = Setlist::Entry.new(kind: :song, track: track_row('宮本佳那子'))

      assert_not_includes(live.program.track_text(entry), '宮本佳那子')
    end

    # ⚠ **合成名義でも隠す**（実データは `キュアソード/剣崎真琴(CV:宮本佳那子)`）。
    def test_a_composite_own_credit_is_hidden
      entry = Setlist::Entry.new(kind: :song, track: track_row('キュアソード/剣崎真琴(CV:宮本佳那子)'))

      assert_not_includes(live.program.track_text(entry), 'キュアソード')
    end

    # 🔴 **共演曲も隠す**（2026-08-22・オーナー判断・#155）。⚠⚠ **劇中設定では、
    # 高橋さんとの曲なども「カバーではなく自分の歌」として歌っている**ので、
    # ⚠ **共演者の名義はその前提では情報を足さない。**
    def test_a_shared_credit_is_hidden
      entry = Setlist::Entry.new(kind: :song, track: track_row('五條真由美&宮本佳那子'))
      text = live.program.track_text(entry)

      assert_not_includes(text, '五條真由美')
      assert_not_includes(text, '宮本佳那子')
    end

    # 🔴 **中黒で並んだ共演名義も隠す。**
    #
    # ⚠⚠ **これは PR #134 で「隠さない」と決めた形そのもの**（実データの
    # `リワインドメモリー`）。⚠ **当時の理由は「五條真由美ごと消えるから」**だったが、
    # 🔴 **#155 でそれを「隠してよい」と決めたので、避ける理由が無くなった。**
    #
    # ⚠ **中黒を区切りとみなすかに関わらず同じ答えになる**（→ `own_credit?`）。
    def test_a_middle_dot_credit_is_hidden
      entry = Setlist::Entry.new(kind: :song, track: track_row('五條真由美・宮本佳那子'))

      assert_not_includes(live.program.track_text(entry), '五條真由美')
    end

    # ⚠ 区切りだけが残るのは自分の名義が並んでいるだけ（隠す）。
    def test_own_names_in_a_row_are_still_hidden
      entry = Setlist::Entry.new(kind: :song, track: track_row('キュアソード・剣崎真琴'))

      assert_not_includes(live.program.track_text(entry), 'キュアソード')
    end

    # ⚠⚠ **姓名の間に空白がある表記も同じ**（#155）。⚠ **設定は「宮本 佳那子」、
    # 曲データは「宮本佳那子」という揺れが実データにある**（→ `CureApiService.normalize`）。
    def test_a_spaced_own_credit_is_hidden
      entry = Setlist::Entry.new(kind: :song, track: track_row('高橋秀幸 & 宮本 佳那子'))
      text = live.program.track_text(entry)

      assert_not_includes(text, '高橋秀幸')
      assert_not_includes(text, '佳那子')
    end

    # 🔴 **括弧の中も見る**（2026-08-23 のオーナー判断・#164）。⚠⚠ **別作品の役名義も
    # 隠す** — 実データの `チョキンとLet's GO！`。
    #
    # ⚠ **2026-08-20 は「隠すと『誰の曲か』が消える」として出したままにしていた。**
    # 🔴 **取り下げた理由は「これはバースデーライブに限った話」だから** — ⚠⚠ **当日は
    # 本人の持ち歌というテイで通す。**
    def test_a_role_credit_with_a_cv_note_is_hidden
      entry = Setlist::Entry.new(kind: :song, track: track_row('グロッサムX2(CV:宮本佳那子)'))

      assert_not_includes(live.program.track_text(entry), 'グロッサムX2')
    end

    # ⚠⚠ **`花奈〈CV: 宮本 佳那子〉` は実在の書き方**（→ `CureApiService#split_artist`）。
    # ⚠ **山括弧でも同じ答えになること**（括弧の種類で判定が変わらない）。
    def test_a_role_credit_with_an_angle_bracket_cv_note_is_hidden
      entry = Setlist::Entry.new(kind: :song, track: track_row('花奈〈CV: 宮本 佳那子〉'))

      assert_not_includes(live.program.track_text(entry), '花奈')
    end

    # 🔴 **ユニット名義の括弧の中に自分が居ても隠す**（#164 の本体）。
    # ⚠⚠ **実データの `ありがとうがいっぱい`** — **ユニット名そのものには自分が
    # 入っていないので、括弧を落とすと「自分を含まない名義」に見えていた。**
    def test_a_unit_credit_listing_own_name_in_brackets_is_hidden
      entry = Setlist::Entry.new(kind: :song,
        track: track_row('キュア・レインボーズ(五條真由美・工藤真由・宮本佳那子・池田彩)'))
      text = live.program.track_text(entry)

      assert_not_includes(text, 'キュア・レインボーズ')
      assert_not_includes(text, '五條真由美')
    end

    # 🔴 **コーラスは本人の判定に使わない**（2026-08-23・オーナー・**#177**）。
    #
    # ⚠⚠ **#164 の「コーラス表記で並んでいても隠す」を取り下げた形。**⚠ **実データの
    # `DANZEN!ふたりはプリキュア ~唯一無二の光たち~`**（本編・2 行）で、
    # 🔴 **コーラスでの参加はその曲を本人の曲にしない**ので、**名義は出す。**
    #
    # ⚠ **`own_units`（#177）で本人の曲を増やす向きだけでなく、
    # 減らす向きにも同じ規則が効く。**
    def test_a_chorus_only_credit_is_shown
      entry = Setlist::Entry.new(kind: :song,
        track: track_row('五條真由美(コーラス:うちやえゆか・宮本佳那子)'))

      assert_includes(live.program.track_text(entry), '五條真由美')
    end

    # ⚠ **落とすのはコーラスの区画だけ** — **主名義が本人なら隠す。**
    def test_a_credit_with_own_name_and_a_chorus_is_hidden
      entry = Setlist::Entry.new(kind: :song,
        track: track_row('宮本佳那子/コーラス:ヤング・フレッシュ'))

      assert_not_includes(live.program.track_text(entry), '宮本佳那子')
    end

    # ⚠ **自分を含まない名義は本編でも出す**（隠すのは自分が居るときだけ）。
    def test_an_unrelated_credit_is_shown_in_the_program
      entry = Setlist::Entry.new(kind: :song, track: track_row('高橋秀幸 & 内田順子'))

      assert_includes(live.program.track_text(entry), '高橋秀幸')
    end

    # ⚠⚠ **ゲストコーナーは必ず出す** — **他の歌手の持ち歌なので名義が意味を持つ。**
    def test_a_cover_credit_is_always_shown
      entry = Setlist::Entry.new(kind: :cover, track: track_row('宮本佳那子'))

      assert_includes(live.program.track_text(entry), '宮本佳那子')
    end

    # ⚠ **ライブでは曲名の括弧書きを落とす**（#119）。
    def test_the_program_drops_brackets_from_the_name
      entry = Setlist::Entry.new(kind: :song,
        track: track_row('宮本佳那子', name: 'パジャマジャ(光るパジャマCM曲)'))
      text = live.program.track_text(entry)

      assert_includes(text, '♪ パジャマジャ')
      assert_not_includes(text, '光るパジャマ')
    end

    # ⚠⚠ **カバーの断りの後ろは 1 行アキ**（#122）。
    def test_the_cover_prefix_is_followed_by_a_blank_line
      entry = Setlist::Entry.new(kind: :cover, track: track_row('池田 彩', name: 'カバーの曲'))
      lines = live.program.track_text(entry).lines.map(&:chomp)

      assert_equal(config['/live/setlist/cover_prefix'], lines.first)
      assert_equal('', lines[1])
      assert_equal('♪ カバーの曲', lines[2])
    end

    # ⚠⚠ **下見は投稿と同じ口を通す**（#62）。⚠ **「ライブでどう見えるか」の正本を
    # 下見の側に写さない。**
    def test_the_preview_uses_the_same_presenter
      entry = Setlist::Entry.new(kind: :song,
        track: track_row('宮本佳那子', name: 'スマイル!(テレビサイズ)'))
      presenter = live.program.track_presenter(entry)

      assert_equal('スマイル！', presenter.name)
      assert_nil(presenter.credit)
    end

    # ⚠⚠ **下見（`makoto live setlist --mc`）は投稿と同じ口を通す**（#62）。
    # ⚠ **「何本目の MC がどの原稿になるか」の正本を 2 つに割らない** — 下見と実際の
    # 投稿が食い違うと、下見そのものが信用できなくなる。
    def test_mc_text_is_shared_with_the_preview
      add('live_mc', 'MC その 1')
      add('live_mc', 'MC その 2')
      program = live.program
      time = jst(11, 4, 13, 0)
      entries = program.setlist(time).entries.select(&:mc?)

      assert_equal(2, program.mc_size(time))
      assert_equal(entries.map {|entry| program.mc_text(entry, time)},
        mc_times(program.setlist(time)).map {|at| program.call(at)})
    end

    # ⚠ 原稿が 1 本も無ければ下見の側も nil（枠が素通しになることを表示できる）。
    def test_mc_text_without_scripts_is_nil
      program = live.program
      time = jst(11, 4, 13, 0)
      entry = program.setlist(time).entries.find(&:mc?)

      assert_equal(0, program.mc_size(time))
      assert_nil(program.mc_text(entry, time))
    end

    # ⚠ MC の原稿が 1 本も無ければその枠は投稿しない（例外にしない）。
    def test_mc_without_scripts_posts_nothing
      list = live.program.setlist(jst(11, 4, 13, 0))
      index = list.entries.each_index.find {|i| list.at(i).mc?}

      assert_nil(live.program.call(live.timetable.times(Date.new(2026, 11, 4))[index]))
    end

    # ⚠⚠ **開始告知にはミュート導線を書く**（#13 の完了条件・参加は任意）。
    # 仕組みとしては「その日の原稿が出ること」まで。
    def test_open_and_close_use_the_script
      add('live_open', 'SONGBIRD PARTY 2026 スタートです！聴きたくない方はミュートしてくださいね')
      add('live_close', 'これでおしまいです。また来年、会いに来てね')

      assert_includes(live.selector('open').call(jst(11, 4, 12, 0)), 'ミュート')
      assert_includes(live.selector('close').call(jst(11, 4, 20, 0)), 'また来年')
    end

    # ⚠ 告知は当日以外には出ない（枠は毎日あるので、ここが nil を返さないと毎日出る）。
    def test_open_is_silent_on_other_days
      add('live_open', 'スタートです')

      assert_nil(live.selector('open').call(jst(6, 15, 12, 0)))
    end

    # ⚠ 前日（11/3）の増量は**別の枠**。予告の枠を広げると 11/1 と 11/2 も一緒に増える。
    def test_eve_is_a_separate_slot_on_the_day_before
      add('live_eve', '明日はバースデーライブです', day: 3)

      assert_equal(8, live.timetable('eve').size(Date.new(2026, 11, 3)))
      assert_equal("明日はバースデーライブです\n#{config['/live/hashtag']}",
        job_source(live.eve_job).call(jst(11, 3, 13, 0)))
    end

    # ⚠⚠ **前日増量は 1 日に 8 本出る。乱択だと同じ原稿が何度も出て、出ない原稿が残る。**
    # 枠の順に頭から消化すること。
    def test_eve_consumes_the_scripts_in_order
      ['1 本目', '2 本目', '3 本目'].each {|body| add('live_eve', body, day: 3)}
      source = ScriptRotation.new(selector: live.selector('eve'), timetable: live.timetable('eve'))
      times = live.timetable('eve').times(Date.new(2026, 11, 3))

      assert_equal(['1 本目', '2 本目', '3 本目', '1 本目'],
        times.first(4).map {|time| source.call(time)})
    end

    # ⚠ 前日以外には出ない（枠は毎日あるので、ここが nil を返さないと毎日出る）。
    def test_eve_is_silent_on_other_days
      add('live_eve', '明日はバースデーライブです', day: 3)
      source = ScriptRotation.new(selector: live.selector('eve'), timetable: live.timetable('eve'))

      assert_nil(source.call(jst(11, 4, 13, 0)))
      assert_nil(source.call(jst(6, 15, 13, 0)))
    end

    # 🔴 **#114 の `live-eve` ぶん。**⚠⚠ **`ScriptRotation` は `MessageSelector#call` を
    # 通らない**（`list` を使う）ので、⚠ **`call` に警告を足しただけではここに穴が残る。**
    def test_eve_reports_silence_when_the_script_is_missing
      selector = live.selector('eve')
      source = ScriptRotation.new(selector: selector, timetable: live.timetable('eve'))
      recorder = with_recorder(selector) do
        assert_nil(source.call(jst(11, 3, 13, 0)))
      end

      assert_include(recorder, 'no message for the reserved date')
    end

    # ⚠ 前日以外は黙る。⚠⚠ **枠は毎日ある**ので、ここで警告すると平常日が毎日黄色になる。
    def test_eve_does_not_report_on_other_days
      selector = live.selector('eve')
      source = ScriptRotation.new(selector: selector, timetable: live.timetable('eve'))
      recorder = with_recorder(selector) do
        assert_nil(source.call(jst(6, 15, 13, 0)))
      end

      assert_empty(recorder)
    end

    # ⚠⚠ **台本の type が記念日に登録されていなければ作らせない。**登録が無いと
    # 日付を持たない台本が段 5 に混ざって毎日出るが、それは 11/4 まで気付けない。
    def test_rejects_a_type_that_is_not_an_anniversary
      config['/live/mc/type'] = 'chatter'

      assert_raise(Ginseng::ConfigError) {live.jobs}
    end

    # ⚠ ライブの日の正本は /message/anniversary（設定を 2 箇所に割らない）。
    def test_live_day_comes_from_the_anniversary_registration
      assert(live.program.live_day?(jst(11, 4, 13, 0)))
      refute(live.program.live_day?(jst(11, 3, 13, 0)))
    end
  end
end
