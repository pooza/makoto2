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

    # ⚠ 枠の外（12:00 の告知の時刻・20:00 以降）では曲を返さない。
    def test_program_is_silent_outside_the_slot
      assert_nil(live.program.call(jst(11, 4, 12, 0)))
      assert_nil(live.program.call(jst(11, 4, 20, 0)))
      assert_nil(live.program.call(jst(11, 4, 23, 0)))
    end

    # ⚠⚠ **MC は原稿を頭から順に消化する。**乱択だと同じ原稿が何度も出て、出ない
    # 原稿が残る。⚠ 用意した本数より枠が多ければ頭に戻る。
    def test_mc_rotates_through_the_scripts_in_order
      add('live_mc', 'MC その 1')
      add('live_mc', 'MC その 2')
      program = live.program
      list = program.setlist(jst(11, 4, 13, 0))
      mc_times = list.entries.each_index.select {|i| list.at(i).mc?}
        .map {|i| live.timetable.times(Date.new(2026, 11, 4))[i]}

      assert_operator(mc_times.size, :>=, 3)
      assert_equal(['MC その 1', 'MC その 2', 'MC その 1'],
        mc_times.first(3).map {|time| program.call(time)})
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
