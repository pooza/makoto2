module Makoto
  # 原稿の運用操作（#12 / #50）。⚠⚠ **`export` は正本を `makoto-scripts` へ移すための口**
  # （#224）。🔴 **本文を public のこのリポジトリに出さない**ので、**書き出し先はファイルだけ。**
  class MessageCommandTest < TestCase
    def setup
      super
      @repository = MessageRepository.new(corpus_db)
      @dir = Dir.mktmpdir('makoto-export')
    end

    def teardown
      FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
      super
    end

    def path
      return File.join(@dir, 'morning.yaml')
    end

    def command(options = {})
      subject = MessageCommand.new
      subject.options = {out: path, type: 'morning', force: false}.merge(options)
      subject.instance_variable_set(:@repository, @repository)
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

    def export(options = {})
      capture {command(options).export}
      return YAML.safe_load_file(path, permitted_classes: [Date])
    end

    # 🔴 **取り込みの形式で出る**（`slug` / `type` / `body`）。⚠ **`slug` は id 順の通し番号。**
    def test_export_writes_the_import_format
      records = export

      assert_equal(['morning-0001', 'morning-0002'], records.map {|r| r['slug']})
      assert_equal(['morning'], records.map {|r| r['type']}.uniq)
      assert_include(records.map {|r| r['body']}, 'テスト用の原稿（通年の朝挨拶）')
    end

    # ⚠⚠ **季節と日付も出る**（出さないと移送で落ちる）。
    def test_export_keeps_the_season_and_the_date
      records = export(type: 'morning,holiday')
      seasonal = records.find {|r| r['season']}
      dated = records.find {|r| r['date']}

      assert_equal([6, 7, 8], seasonal['season'])
      assert_equal('01-01', dated['date'])
      assert_equal('holiday', dated['type'])
    end

    # 🔴 **書き出したものをそのまま取り込めること**（⚠ 移送はこの往復が全部）。
    def test_export_can_be_imported_back
      export(type: 'morning,holiday')
      db = Database.migrate(Database.connect('sqlite:/'))
      result = ScriptImporter.new(repository: MessageRepository.new(db)).import(path)

      assert_equal(3, result.created)
      assert_equal(corpus_db[:message].where(type: ['morning', 'holiday']).select_map(:body).sort,
        db[:message].select_map(:body).sort)
    ensure
      db&.disconnect
    end

    # ⚠ **`slug` を持つ行はその `slug` を保つ**（付け直すと取り込みで二重になる）。
    def test_export_keeps_an_existing_slug
      corpus_db[:message].insert(slug: 'morning-taken', type: 'morning', body: '既に台本由来')

      assert_include(export.map {|r| r['slug']}, 'morning-taken')
    end

    # ⚠ **落とすと決めた原稿は書き出さない**（#60 の古びた 10 件がこの経路で落ちる）。
    def test_export_excludes_the_given_ids
      records = export(exclude: '2001')

      assert_not_include(records.map {|r| r['body']}, 'テスト用の原稿（通年の朝挨拶）')
    end

    # ⚠⚠ **既にあるファイルを黙って上書きしない。**
    def test_export_refuses_to_overwrite
      File.write(path, '先にあるもの')

      assert_raise(SystemExit) {capture {command.export}}
      assert_equal('先にあるもの', File.read(path))
    end
  end
end
