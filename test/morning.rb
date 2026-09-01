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

    def jst(month, day, hour = 7, year: 2026)
      return Time.new(year, month, day, hour, 0, 0, '+09:00')
    end

    # 通年の原稿を足す。⚠ **季節も日付も持たないので段 5（無指定）に入る。**
    def add(body, type: 'morning')
      return @repository.create(type: type, body: body)
    end

    def greeting
      return config['/morning/greeting']
    end

    # ⚠ 枠は 1 日 1 本。**`finish` は含まない（半開区間）**ので 07:00 だけ。
    # 🔴 07:00 は旧アカウントの実測（→ config）。
    def test_timetable_has_one_slot_a_day
      times = morning.timetable.times(Date.new(2026, 9, 1))

      assert_equal([jst(9, 1)], times)
    end

    def test_job
      job = morning.job

      assert_equal(Morning::NAME, job.name)
      assert_equal(morning.timetable.to_s, job.timetable.to_s)
    end

    # ⚠ 冪等キーは枠の頭から作る。⚠⚠ **07:00 JST は前日の 22:00 UTC。**
    def test_idempotency_key_comes_from_the_slot
      assert_equal('morning-20260831T220000Z', morning.job.idempotency_key(jst(9, 1)))
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

    # 🔴 **日曜 08:30〜09:00 の実況の窓に枠を置かない**（#172）。⚠⚠ **人が話している
    # ところへ定型文を差し込むのは上書き。**
    def test_rejects_a_slot_in_the_commentary_window
      config['/morning/timetable/start'] = '08:45'
      config['/morning/timetable/finish'] = '08:46'

      assert_raise(Ginseng::ConfigError) {morning.job}
    end

    # ⚠ 既定の 07:00 は窓の外（＝そのまま起動できる）。
    def test_the_default_slot_is_accepted
      assert_equal(Morning::NAME, morning.job.name)
    end
  end
end
