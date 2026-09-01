module Makoto
  # 朝挨拶の下見（#17）。⚠⚠ **1 日 1 本の枠なので、完了条件（連日で同じ挨拶が続かない）
  # を実機で確かめると 1 週間かかる。**🔴 **先の日を読めることが、そのまま検証の手段。**
  class MorningCommandTest < TestCase
    def setup
      super
      @repository = MessageRepository.new(corpus_db)
    end

    def morning
      @morning ||= Morning.new(repository: @repository)
      return @morning
    end

    def command(options = {})
      subject = MorningCommand.new
      subject.options = {days: MorningCommand::DEFAULT_DAYS}.merge(options)
      subject.instance_variable_set(:@morning, morning)
      return subject
    end

    def capture
      original = $stdout
      $stdout = StringIO.new
      yield
      return $stdout.string
    ensure
      $stdout = original
    end

    # ⚠ 日付を渡した日から順に、1 日ぶんずつ出る。
    def test_preview_prints_a_day_each
      3.times {|i| @repository.create(type: 'morning', body: "日替わりの原稿 #{i}")}

      output = capture {command(date: '2026-09-01').preview}

      assert_equal(['2026-09-01 (Tue)', '2026-09-02 (Wed)', '2026-09-03 (Thu)'],
        output.lines.map(&:chomp).grep(/\A\d{4}-/).first(3))
    end

    # 🔴 **定型挨拶ごと出す。**⚠⚠ **下見で挨拶が見えないと、実際の投稿と別物を読む
    # ことになる**（→ `MorningSource`）。
    def test_preview_shows_the_greeting
      output = capture {command(date: '2026-09-01', days: 1).preview}

      assert_include(output, config['/morning/greeting'])
      assert_include(output, 'テスト用の原稿（通年の朝挨拶）')
    end

    # ⚠ **連日で同じ挨拶が続かないこと**を、下見のまま目で確かめられる。
    def test_preview_does_not_repeat_on_consecutive_days
      3.times {|i| @repository.create(type: 'morning', body: "日替わりの原稿 #{i}")}

      bodies = capture {command(date: '2026-09-01', days: 7).preview}
        .lines.map(&:chomp).grep(/\A {2}(テスト用|日替わり)/)

      assert_equal([], bodies.each_cons(2).select {|a, b| a == b})
    end

    # ⚠⚠ **原稿が無い日は「投稿しない」と書く。**⚠ 空行だけだと、下見が壊れたのか
    # 原稿が無いのか読めない。
    def test_preview_marks_a_silent_day
      db = Database.migrate(Database.connect('sqlite:/'))
      @morning = Morning.new(repository: MessageRepository.new(db))

      output = capture {command(date: '2026-09-01', days: 1).preview}

      assert_include(output, '原稿はありません')
    ensure
      db&.disconnect
    end

    # ⚠ 0 日・負の日数は黙って 1 日に倒さない。
    def test_preview_rejects_a_bad_days
      assert_raise(SystemExit) {capture {command(date: '2026-09-01', days: 0).preview}}
    end

    def test_slot_prints_the_timetable_and_the_window
      output = capture {command.slot}

      assert_include(output, "#{Morning::NAME}: #{morning.timetable}")
      assert_include(output, CommentaryWindow.new.to_s)
    end

    # ⚠⚠ **ホストの TZ で「今日」を出さない。**⚠ **UTC のホストでは日付が 1 日ずれる**
    # （→ `ScriptImporter.parse_preview_date` の注記）。
    def test_start_date_defaults_to_today_in_the_configured_timezone
      today = TZInfo::Timezone.get(config['/scheduler/timezone'])
        .utc_to_local(Time.now.getutc).to_date

      assert_equal(today, command.send(:start_date, nil))
    end

    def test_start_date_reads_the_option_as_the_importer_does
      assert_equal(Date.new(2026, 11, 4), command.send(:start_date, '2026-11-04'))
      assert_equal(Date.new(Date.today.year, 11, 4), command.send(:start_date, '11-4'))
    end

    def test_start_date_rejects_a_broken_value
      assert_raise(Ginseng::ValidateError) {command.send(:start_date, 'あした')}
    end
  end
end
