module Makoto
  # 下見コマンド（#62）。⚠⚠ **`docs/CLAUDE.md` が「#69 / #73 は #62 の下見を作って
  # 初めて見えた」と書いているとおり、下見は本番の並びを判断する唯一の目。**
  # ⚠ **ここが黙って壊れると、下見を信じた判断ごと間違える**（#80 の黄 10）。
  #
  # ⚠ **`repeat_mark` は表示だけの飾りではない** — `@used` に状態を溜めて「2 回目」を
  # 数えており、**計算ロジックを持つ。**
  class LiveCommandTest < TestCase
    def setup
      super
      @messages = MessageRepository.new(corpus_db)
      @tracks = TrackRepository.new(corpus_db)
      seed_tracks
    end

    def live
      @live ||= Live.new(repository: @messages, tracks: @tracks, cure_api: cure_api)
      return @live
    end

    # ⚠⚠ **実サーバーへは飛ばさない。**カバーは 0 件に固定してあるので、
    # ここで見たいのは「名義を引きに行かないこと」だけ。
    def cure_api
      return Struct.new(:x) do
        def available? = true
        def stale? = false
        def singer?(_name) = false
      end.new(nil)
    end

    def date
      return Date.new(2026, 11, 4)
    end

    def time
      return Time.new(2026, 11, 4, 13, 0, 0, '+09:00')
    end

    # ⚠ フィクスチャの曲は 2 曲しかないので、並びを見るぶんだけ足す（→ test/live.rb）。
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

    def add_scripts(size)
      size.times {|i| @messages.create(type: 'live_mc', body: 'MC %02d' % i, year: 2026, month: 11, day: 4)}
    end

    def command(options = {})
      subject = LiveCommand.new
      subject.options = {mc: false}.merge(options)
      subject.instance_variable_set(:@live, live)
      return subject
    end

    def setlist(slots)
      return Setlist.new(date: date, slots: slots, repository: @tracks, cure_api: cure_api)
    end

    def mc_entries(total)
      return Array.new(total) {|i| Setlist::Entry.new(kind: :mc, ordinal: i, mc_total: total)}
    end

    def capture
      original = $stdout
      $stdout = StringIO.new
      yield
      return $stdout.string
    ensure
      $stdout = original
    end

    # ⚠⚠ **日付のまま渡す。**時刻を作るとホストの TZ で解釈され、日本の外で下見すると
    # 11/4 が 11/5 になる。
    def test_preview_date_parses_the_option
      assert_equal(date, command.send(:preview_date, '2026-11-04'))
    end

    def test_preview_date_defaults_to_today
      assert_equal(Date.today, command.send(:preview_date, nil))
      assert_equal(Date.today, command.send(:preview_date, ''))
    end

    # ⚠ 壊れた指定は黙って今日に倒さない（下見の日付を間違えたことに気付けない）。
    #
    # ⚠⚠ **ただし `Date.parse` は緩い。**⚠ **`--date=11-4` が 8 月 11 日になる**という
    # 食い違いが残っている（同じ文字列を `makoto message add --date` は 11 月 4 日と
    # 読む）。**ここでは現状の境界だけを固定する** → #96。
    def test_preview_date_rejects_a_broken_value
      assert_raise(Ginseng::ValidateError) {command.send(:preview_date, 'あした')}
      assert_raise(Ginseng::ValidateError) {command.send(:preview_date, '2026-13-40')}
    end

    # ⚠ 原稿が枠に足りていれば、注記は付かない。
    def test_mc_summary_without_a_shortage
      add_scripts(40)
      list = setlist(20)

      assert_match(%r{MC \d+ 枠 / 原稿 40 本\z}, command.send(:mc_summary, list, time))
    end

    # 🔴 **#69 の再発検知。**⚠⚠ **原稿より枠が多いと、その差だけ同じ原稿が 2 回出る。**
    # ⚠ **下見でここを読めることが #62 の目的**（実機では 8 時間流さないと分からない）。
    def test_mc_summary_reports_the_shortage
      add_scripts(2)
      list = setlist(20)
      slots = list.entries.count(&:mc?)
      summary = command.send(:mc_summary, list, time)

      assert_include(summary, "MC #{slots} 枠 / 原稿 2 本")
      assert_include(summary, "⚠ #{slots - 2} 本が 2 回出る")
    end

    # ⚠ 原稿が 1 本も無い日は注記を出さない（不足ではなく「まだ書いていない」）。
    def test_mc_summary_without_any_script
      list = setlist(20)
      slots = list.entries.count(&:mc?)

      assert_equal("MC #{slots} 枠 / 原稿 0 本", command.send(:mc_summary, list, time))
    end

    # 🔴 **黄 10 の本体。**⚠⚠ **`repeat_mark` は `@used` に状態を溜めて数える。**
    # ⚠ **原稿 2 本を 4 枠で消化すれば、必ず 2 枠が「2 回目」になる。**
    def test_repeat_mark_counts_the_second_time
      add_scripts(2)
      subject = command
      marks = mc_entries(4).map {|entry| subject.send(:repeat_mark, entry, time)}

      assert_equal(2, marks.count {|mark| mark.include?('↻2回目')})
      assert_equal(2, marks.count(&:empty?))
    end

    # ⚠ 1 回目には何も付かない（付くと全枠が「再演」に見える）。
    def test_repeat_mark_is_silent_on_the_first_time
      add_scripts(4)
      subject = command

      assert_equal(['', '', '', ''], mc_entries(4).map {|entry| subject.send(:repeat_mark, entry, time)})
    end

    # ⚠⚠ **3 回目は「2 回目」と書かない。**⚠ 台本が薄い日ほど回数が伸びるので、
    # **何回目かが読めること**がここの値打ち。
    def test_repeat_mark_counts_beyond_the_second_time
      add_scripts(1)
      subject = command
      marks = mc_entries(3).map {|entry| subject.send(:repeat_mark, entry, time)}

      assert_equal(['', ' ↻2回目', ' ↻3回目'], marks)
    end

    # ⚠ 原稿が無ければ数えようがない（0 除算にも落ちない）。
    def test_repeat_mark_without_any_script
      subject = command

      assert_equal(['', ''], mc_entries(2).map {|entry| subject.send(:repeat_mark, entry, time)})
    end

    # ⚠ `--mc` を付けなければ本文は出さない（160 行が読めなくなる）。
    def test_label_without_the_mc_option
      add_scripts(4)
      entry = mc_entries(4).first

      assert_equal(entry.to_s, command.send(:label, entry, time))
    end

    def test_label_shows_the_script_with_the_mc_option
      add_scripts(4)
      entry = mc_entries(4).first

      assert_include(command(mc: true).send(:label, entry, time), 'MC 00')
    end

    # ⚠⚠ **原稿がまだ無い枠は「投稿しない」と分かること。**⚠ **MAKOTO は 8/15〜10/31 が
    # この状態**なので、空欄と壊れているのが見分けられないと下見が読めない。
    def test_label_reports_a_slot_without_a_script
      entry = mc_entries(4).first

      assert_include(command(mc: true).send(:label, entry, time), '原稿が無いので投稿しない')
    end

    # ⚠ 曲の枠は `--mc` に関係なくそのまま出す。
    def test_label_of_a_song_is_the_entry_itself
      entry = setlist(20).entries.find {|item| !item.mc?}

      assert_equal(entry.to_s, command(mc: true).send(:label, entry, time))
    end

    # ⚠⚠ **8 時間 160 枠を目視で確認するための口**なので、⚠ **枠が 1 行ずつ、
    # 時刻付きで並ぶこと**が下見の最低条件。
    def test_dump_lists_every_slot_with_its_time
      add_scripts(4)
      list = setlist(20)
      output = capture {command.send(:dump, list, live.timetable, date)}
      lines = output.lines

      assert_include(lines.first, '2026-11-04')
      assert_include(output, '[0]')
      assert_include(output, '[19]')
      assert_equal(20, lines.count {|line| line.match?(/\A\d\d:\d\d \[\d+\]/)})
    end

    # ⚠ `--limit` は表示だけを切る。⚠⚠ **並びそのものは全枠ぶん組む**（切った並びを
    # 見せると、下見と本番が食い違う）。
    def test_dump_limits_the_listing_only
      add_scripts(4)
      list = setlist(20)
      output = capture {command(limit: 5).send(:dump, list, live.timetable, date)}

      assert_include(output, '20 枠')
      assert_equal(5, output.lines.count {|line| line.match?(/\A\d\d:\d\d \[\d+\]/)})
    end
  end
end
