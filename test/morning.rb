module Makoto
  # 朝挨拶（#17）。⚠⚠ **完了条件は「連日で同じ挨拶が続かない」「上書き原稿がある日は
  # そちらが出る」**の 2 つ。🔴 **1 日 1 本の枠なので、実機では 1 週間待たないと
  # 分からない** — ⚠ **ここで日付を渡して先の日を読む。**
  class MorningTest < TestCase
    def setup
      super
      @repository = MessageRepository.new(corpus_db)
    end

    def morning(repository = @repository)
      return Morning.new(repository: repository)
    end

    # ⚠ **既定は枠の頭（08:00）**（→ config・#247）。
    def jst(month, day, hour = 8, year: 2026)
      return Time.new(year, month, day, hour, 0, 0, '+09:00')
    end

    # 通年の原稿を足す。⚠ **季節も日付も持たないので段 5（無指定）に入る。**
    def add(body, type: 'morning')
      return @repository.create(type: type, body: body)
    end

    def greeting
      return config['/morning/greeting']
    end

    # ⚠ 枠は 1 日 1 本。**`finish` は含まない（半開区間）**ので 08:00 だけ。
    # 🔴 **08:00 は元ネタ『キッズ劇場!!』の放送開始時刻**（→ config・#247）。
    def test_timetable_has_one_slot_a_day
      times = morning.timetable.times(Date.new(2026, 9, 1))

      assert_equal([jst(9, 1)], times)
    end

    def test_job
      job = morning.job

      assert_equal(Morning::NAME, job.name)
      assert_equal(morning.timetable.to_s, job.timetable.to_s)
    end

    # ⚠ 冪等キーは枠の頭から作る。⚠⚠ **08:00 JST は前日の 23:00 UTC。**
    #
    # 🔴 **07:00 と 08:00 は別のキー**（#247）。⚠⚠ **切り替える日に両方の枠が動くと、
    # どちらも「1 回目」として通る** — ⚠ **デプロイは 07:00 より前か 08:00:30 以降。**
    def test_idempotency_key_comes_from_the_slot
      assert_equal('morning-20260831T230000Z', morning.job.idempotency_key(jst(9, 1)))
      assert_not_equal(morning.job.idempotency_key(jst(9, 1, 7)),
        morning.job.idempotency_key(jst(9, 1)))
    end

    # ⚠ 使ってよい原稿は日替わり（`morning`）と特定日（`holiday`）の 2 つ。
    def test_types
      assert_equal(['morning', 'holiday'], morning.types)
    end

    # 🔴 **定型挨拶はコード側が付ける。**⚠⚠ **`morning` 237 件に「おはよう」は
    # 1 件も無い**（実測 0 件）ので、これが無いと挨拶なしの投稿になる。
    def test_greeting_is_prepended_to_the_daily_message
      text = morning.source.call(jst(9, 1))

      assert_equal(greeting, text.lines.first.chomp)
      assert_equal('テスト用の原稿（通年の朝挨拶）', text.lines.last.chomp)
    end

    # ⚠⚠ **日付が特定された原稿は挨拶を自分で持つ。**⚠ **定型挨拶を足すと二重になる**
    # （4/1 のおふざけは挨拶ごと差し替わる形 → #12 / #50）。
    def test_the_dated_message_keeps_its_own_greeting
      text = morning.source.call(jst(1, 1))

      assert_equal('テスト用の原稿（元日）', text)
    end

    # ⚠⚠ **上書き原稿がある日はそちらが出る**（#17 の完了条件）。
    def test_the_dated_message_wins
      record = morning.source.find(jst(1, 1))

      assert_equal('holiday', record[:type])
    end

    # 🔴 **#17 の完了条件。**⚠⚠ **乱択だと 1 日 1 本の枠では連日で同じ原稿を引きうる**
    # ので、日数で順に送る（→ `MorningSource`）。
    def test_no_repeat_on_consecutive_days
      3.times {|i| add("日替わりの原稿 #{i}")}
      source = morning.source
      bodies = (1..30).map {|day| source.call(jst(9, 1) + (day * 86_400))}

      assert_equal([], bodies.each_cons(2).select {|a, b| a == b})
    end

    # ⚠ **順送りなので、母集合の件数ぶん回れば全部出る**（出ない原稿が残らない）。
    def test_the_rotation_covers_every_message
      3.times {|i| add("日替わりの原稿 #{i}")}
      source = morning.source
      bodies = (0..3).map {|day| source.call(jst(9, 2) + (day * 86_400))}

      assert_equal(4, bodies.uniq.size)
    end

    # 🔴 **季節の原稿が 1 件しかない月でも、毎日それにならない**（Codex の P1）。
    # ⚠⚠ **実データの 5 月がこの形**（1 件・→ docs/makoto-legacy.md）で、⚠ **段 4 が
    # 毎日勝つ形だと 31 日とも同じ挨拶**になる。🔴 **季節は月の中に散らす。**
    def test_a_single_seasonal_message_does_not_repeat
      3.times {|i| add("日替わりの原稿 #{i}")}
      # フィクスチャの 6〜8 月は季節の原稿が 1 件だけ。
      bodies = (1..8).map {|day| morning.source.call(jst(6, day))}

      assert_equal([], bodies.each_cons(2).select {|a, b| a == b})
      assert_operator(bodies.uniq.size, :>, 1)
    end

    # ⚠ **散らしても季節の原稿は出る**（⚠⚠ **1 件なら月に 1 日**）。
    def test_the_seasonal_message_is_used_once_a_month
      3.times {|i| add("日替わりの原稿 #{i}")}
      bodies = (1..30).map {|day| morning.source.call(jst(6, day))}

      assert_equal(1, bodies.count {|body| body.include?('テスト用の原稿（夏の朝挨拶）')})
    end

    # ⚠⚠ **日付が特定された原稿は散らしの対象にしない。**🔴 **その日はその原稿が出るのが
    # 上書きの意味**（#12）。⚠ 元日は毎年同じ原稿でよい。
    def test_the_dated_message_is_not_rotated_away
      bodies = [2026, 2027].map {|year| morning.source.call(jst(1, 1, year: year))}

      assert_equal(['テスト用の原稿（元日）'] * 2, bodies)
    end

    # 🔴 **母集合が入れ替わる日（月替わり）でも続かないこと**（Codex の P2）。
    # ⚠⚠ **日ごとに違う大きさの配列を独立に割る**ので、⚠ **前日と同じ位置に落ちうる。**
    #
    # ⚠ **季節の原稿を月ごとに違う件数で置いて、1 年ぶん通す**（月替わりが 12 回入る）。
    def test_no_repeat_across_the_month_boundaries
      seed_a_year
      source = morning.source
      bodies = (0...365).map {|offset| source.call(Date.new(2026, 1, 1) + offset)}

      assert_equal([], bodies.each_cons(2).select {|a, b| a == b})
    end

    # 月ごとの季節の原稿の件数。🔴 **この並びは、ずらしを入れないと 11/30 → 12/1 で
    # 同じ原稿が 2 日続く**（探索で見つけた形）。⚠⚠ **11 月は 1 件なので通年まで
    # 広がり（5 件）、12 月は季節が無いので通年だけ（4 件）** — ⚠ **大きさの違う配列を
    # 独立に割った結果、同じ原稿に落ちる。**
    SEASONS = {
      1 => 2, 2 => 2, 3 => 1, 4 => 4, 5 => 1, 6 => 1,
      7 => 0, 8 => 4, 9 => 4, 10 => 1, 11 => 1, 12 => 0
    }.freeze

    # 通年 4 件 ＋ 月ごとの季節。⚠ 実データの偏り（5 月がほぼ空）を小さく写したもの。
    # ⚠⚠ **通年を先に作る**（`rotating_list` の並びは `slug` → `id` ＝ 作った順）。
    def seed_a_year
      4.times {|i| @repository.create(type: 'morning', body: "通年の原稿 #{i}")}
      SEASONS.each do |month, size|
        size.times do |i|
          @repository.create(type: 'morning', body: "#{month} 月の原稿 #{i}", seasons: [month])
        end
      end
      return nil
    end

    # 🔴 **周回ごとに並びが変わること**（#223）。⚠⚠ **順送りのままだと「周期で同じ順番」**
    # になる（オーナー: それはイヤ）。
    def test_the_order_changes_every_cycle
      6.times {|i| add("日替わりの原稿 #{i}")}
      source = morning.source
      size = undated_size
      first = (0...size).map {|i| source.find(cycle_head(size) + i)[:id]}
      second = (0...size).map {|i| source.find(cycle_head(size) + size + i)[:id]}

      assert_not_equal(first, second)
      assert_equal(first.sort, second.sort)
    end

    def undated_size
      return morning.selector.undated_list(Date.new(2026, 9, 1)).size
    end

    # ⚠ **周の頭の日付。**⚠⚠ **周は暦に貼り付いていない**（`ユリウス通日 % 本数`）ので、
    # **適当な日から数えると 2 つの周をまたいでしまう。**
    def cycle_head(size)
      return Date.jd(((Date.new(2026, 9, 1).jd / size) + 1) * size)
    end

    # ⚠ **1 周で全件が 1 回ずつ出ること**（組み替えても漏れを作らない）。
    def test_one_cycle_covers_every_message
      6.times {|i| add("日替わりの原稿 #{i}")}
      source = morning.source
      size = undated_size
      ids = (0...size).map {|i| source.find(cycle_head(size) + i)[:id]}

      assert_equal(size, ids.uniq.size)
    end

    # 🔴 **同じ原稿が戻るまで、本数の半分を下回らないこと**（#223）。⚠⚠ **完全に組み替えると
    # 周の境目で最短 2 日まで落ちる**ので、**前半・後半を保ったまま中だけ組み替える。**
    def test_the_gap_never_falls_below_half_the_pool
      9.times {|i| add("日替わりの原稿 #{i}")}
      source = morning.source
      size = undated_size
      seen = {}
      gaps = []
      (0...(size * 4)).each do |offset|
        date = Date.new(2026, 9, 1) + offset
        record = source.find(date)
        gaps.push(offset - seen[record[:id]]) if seen[record[:id]]
        seen[record[:id]] = offset
      end

      assert_operator(gaps.min, :>=, size / 2)
    end

    # 🔴 **季節は年ごとに違う日に出ること**（#223）。⚠⚠ **組み替える前は毎年まったく
    # 同じ日に同じ原稿**だった（実データで 183 / 183 日一致）。
    def test_the_seasonal_order_changes_every_year
      6.times {|i| @repository.create(type: 'morning', body: "6 月の原稿 #{i}", seasons: [6])}
      source = morning.source
      first = (1..30).map {|day| source.find(jst(6, day, year: 2026))[:id]}
      second = (1..30).map {|day| source.find(jst(6, day, year: 2027))[:id]}

      assert_not_equal(first, second)
    end

    # 🔴 **箱をまたいでも同じ並びになること**（#223・Codex の P2）。⚠⚠ **`id` は DB ごとの
    # 採番**なので、**`bydo` と `rubicon` で同じ原稿が別の番号になる** — ⚠ **`id` で並べると
    # ステージングの下見が本番を言い当てられない。**🔴 **鍵は `slug`。**
    def test_the_order_does_not_depend_on_the_database_ids
      dbs = Array.new(2) {Database.migrate(Database.connect('sqlite:/'))}
      repositories = dbs.map {|db| MessageRepository.new(db)}
      # ⚠ 片方だけ先に別の行を入れて、id をずらす。
      repositories.last.create(type: 'test_note', body: 'id をずらすための行')
      ['morning-a', 'morning-b', 'morning-c', 'morning-d'].each do |slug|
        repositories.each {|repository| repository.upsert(slug: slug, type: 'morning', body: slug)}
      end
      dates = (0...8).map {|offset| Date.new(2026, 9, 1) + offset}
      orders = repositories.map do |repository|
        dates.map {|date| morning(repository).source.find(date)[:slug]}
      end

      # ⚠ 組み替わっていること（`slug` の順のままなら鍵が効いていない）。
      assert_not_equal(orders.first, orders.first.sort)
      assert_equal(orders.first, orders.last)
    ensure
      dbs&.each(&:disconnect)
    end

    # ⚠⚠ **状態を持たない。**⚠ **落ちて戻ってきても、下見をやり直しても同じ日は
    # 同じ原稿**（→ docs/CLAUDE.md「進行位置は状態ではなく計算で出す」）。
    def test_the_same_day_gives_the_same_message
      add('日替わりの原稿')

      assert_equal(morning.source.call(jst(9, 3)), morning.source.call(jst(9, 3)))
    end

    # ⚠ **日付を渡しても時刻を渡しても同じ日として扱う**（下見は日付で渡す）。
    def test_a_date_and_a_time_agree
      add('日替わりの原稿')

      assert_equal(morning.source.call(jst(9, 3)), morning.source.call(Date.new(2026, 9, 3)))
    end

    # 🔴 **日付を持つ原稿が季節も持っていても、その日は日付の側が勝つ**（Codex の P2）。
    # ⚠⚠ **`ScriptImporter` は日付と季節の同居を通す**ので、⚠ **どちらの段で勝ったかを
    # 実体の照合で推測すると、上書きを季節と読み違える。**
    def test_a_dated_message_with_seasons_still_wins_on_its_date
      @repository.create(type: 'holiday', body: '七夕の原稿', month: 7, day: 7, seasons: [7])
      3.times {|i| add("日替わりの原稿 #{i}")}

      assert_equal('七夕の原稿', morning.source.call(jst(7, 7)))
    end

    # 🔴 **日替わりの type にも日付は付けられる**（`makoto message add --type=morning
    # --date=...`）。⚠⚠ **その日は原稿が挨拶を自分で持つ側**なので、⚠ **type だけで
    # 判断すると挨拶が二重になる**（Codex の P2）。
    def test_a_dated_message_of_the_daily_type_keeps_its_own_greeting
      @repository.create(type: 'morning', body: 'おはようございます！特別な日です', month: 3, day: 3)

      assert_equal('おはようございます！特別な日です', morning.source.call(jst(3, 3)))
    end

    # 🔴 **日付を持つ原稿は季節の母集合に入れない**（Codex の P2）。⚠⚠ **日付と季節は
    # 同居できる**ので、⚠ **入れると「その日に出す原稿」が月内の別の日にも出る。**
    def test_a_dated_message_never_fills_another_day_of_the_month
      3.times {|i| add("日替わりの原稿 #{i}")}
      @repository.create(type: 'holiday', body: '七夕の原稿', month: 7, day: 7, seasons: [7])
      bodies = (1..31).map {|day| morning.source.call(jst(7, day))}

      assert_equal(1, bodies.count {|body| body.include?('七夕の原稿')})
    end

    # 🔴 **通年が 2 件未満なら逃がさない**（Codex の P2）。⚠⚠ **逃がした先が翌日の
    # 順送りと同じになる**ので、⚠ **連日の重複が 1 日ずれるだけで消えない。**
    # ⚠⚠ **母集合が 2 件未満のときは、そもそも連日で違う原稿を出せない**（原稿を足す
    # 側の話）。
    def test_the_escape_is_skipped_when_the_undated_pool_is_too_small
      seed_a_shared_season_without_undated

      # ⚠ 逃がさないので、月またぎの重複はそのまま（通年 1 件では避けようがない）。
      assert_equal('10 月と 11 月の原稿',
        morning.source.find(jst(11, 1, year: COLLIDING_YEAR))[:body])
    end

    # 10 月の最後の日を季節の日にし、その 1 件だけ 11 月にも属させる。⚠ 通年は
    # フィクスチャの 1 件だけ（＝ 逃がし先が作れない）。
    def seed_a_shared_season_without_undated
      15.times {|i| @repository.create(type: 'morning', body: "10 月の原稿 #{i}", seasons: [10])}
      @repository.create(type: 'morning', body: '10 月と 11 月の原稿', seasons: [10, 11])
      3.times {|i| @repository.create(type: 'morning', body: "11 月の原稿 #{i}", seasons: [11])}
      return nil
    end

    # ⚠⚠ **原稿が 1 件も無ければ投稿しない。**⚠ 枠は毎日あるので、ここが nil を
    # 返さないと例外か空投稿になる。
    def test_silent_without_any_message
      # ⚠ `empty_db` はコーパスを入れた後だと空ではない（同じ接続を使い回す）ので、
      # ここだけ別に作る。
      db = Database.migrate(Database.connect('sqlite:/'))

      assert_nil(morning(MessageRepository.new(db)).source.call(jst(9, 1)))
    ensure
      db&.disconnect
    end

    # ⚠ **定型挨拶は空にすれば付かない**（機能のフラグを別に持たない）。
    def test_the_greeting_can_be_emptied
      config['/morning/greeting'] = ''

      assert_equal('テスト用の原稿（通年の朝挨拶）', morning.source.call(jst(9, 1)))
    end

    # ⚠⚠ **ライブの台本を朝挨拶が横取りしない。**⚠ 許可リストに無い type は日付が
    # 一致しても選ばれない（→ `MessageSelector`）。
    def test_the_live_script_is_never_picked
      records = (1..14).map {|day| morning.source.find(jst(11, day))}

      # ⚠ フィクスチャの 11 月には `live_open`（記念日）と `live_mc` があるが、
      # 許可リストに無いので 1 度も出ない。
      assert_equal(['morning'], records.compact.map {|record| record[:type]}.uniq)
    end

    # 🔴 **日替わりの type を記念日に登録させない。**⚠⚠ **登録すると通年の段から外れ、
    # その日以外は 1 本も引けなくなる** — ⚠ **表面化するのは翌朝なので起動時に落とす。**
    def test_rejects_the_type_registered_as_an_anniversary
      # ⚠ 記念日に登録済みの type（予告）を日替わりに指したのと同じ形。
      config['/morning/type'] = config['/announcement/type']

      assert_raise(Ginseng::ConfigError) {morning.job}
    end

    # ⚠ 既定の 08:00 は窓の外（＝そのまま起動できる）。🔴 **窓の検査そのものは
    # `Scheduler#register`**（自分から出す投稿すべてに掛ける → test/scheduler.rb）。
    def test_the_default_slot_is_accepted
      assert_equal(Morning::NAME, morning.job.name)
    end

    # 🔴 **月をまたいで同じ季節の原稿が 2 日続かない**（Codex の P2）。⚠⚠ **季節の原稿は
    # 複数の月を持てる**（`{"season": [6,7,8]}`）ので、⚠ **6 月の最後の 1 件と 7 月の
    # 最初の 1 件が同じ原稿になりうる。**
    # ⚠ **2070 年を使う。**🔴 **並びは年ごとに組み替わる**（#223）ので、⚠⚠ **月末と
    # 翌月頭が同じ原稿に当たる年は限られる** — **この配分では 2070 年と 2113 年**
    # （実測で探した。⚠ **当たらない年で試すと、逃がしを消しても通ってしまう**）。
    COLLIDING_YEAR = 2070

    def test_a_shared_seasonal_message_does_not_span_the_boundary
      seed_a_shared_season
      source = morning.source
      bodies = (29..31).map {|day| source.call(jst(10, day, year: COLLIDING_YEAR))} +
        (1..3).map {|day| source.call(jst(11, day, year: COLLIDING_YEAR))}

      assert_equal([], bodies.each_cons(2).select {|a, b| a == b})
    end

    # 10 月の最後の日を季節の日にし（16 件 > 31 日の半分）、その 1 件だけ 11 月にも
    # 属させる。⚠ 並びは id 順なので、10 月では最後・11 月では最初になる
    # （⚠⚠ **逃がしが無いと 10/31 と 11/1 が同じ原稿になる**）。
    def seed_a_shared_season
      3.times {|i| add("日替わりの原稿 #{i}")}
      15.times {|i| @repository.create(type: 'morning', body: "10 月の原稿 #{i}", seasons: [10])}
      @repository.create(type: 'morning', body: '10 月と 11 月の原稿', seasons: [10, 11])
      3.times {|i| @repository.create(type: 'morning', body: "11 月の原稿 #{i}", seasons: [11])}
      return nil
    end
  end
end
