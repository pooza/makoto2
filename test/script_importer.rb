require 'tmpdir'

module Makoto
  class ScriptImporterTest < TestCase
    setup do
      @db = empty_db
      @repository = MessageRepository.new(@db)
    end

    def importer
      return ScriptImporter.new(repository: @repository)
    end

    def fixture_dir
      return File.join(self.class.fixture_dir, 'script')
    end

    def fixture(name)
      return File.join(fixture_dir, name)
    end

    # ⚠ `makoto message add` で足した原稿の代役。**slug を持たない。**
    def add_by_cli(body = '手で足した原稿')
      return @repository.create(type: 'morning', body: body)
    end

    def slugs
      return @repository.by_slug.order(:slug).select_map(:slug)
    end

    def test_import_a_file
      result = importer.import(fixture('live-test.yaml'))

      assert_equal(3, result.created)
      assert_equal(0, result.updated)
      assert_nil(result.pruned)
      assert_equal(['test-eve-01', 'test-eve-02', 'test-open'], slugs)
    end

    def test_import_a_directory
      importer.import(fixture_dir)

      assert_equal(6, @repository.count)
    end

    # 本文・type・日付が入ること。⚠ `YYYY-MM-DD` は**その年だけ**。
    def test_body_and_date_are_stored
      importer.import(fixture('live-test.yaml'))
      row = @repository.dataset[slug: 'test-eve-01']

      assert_equal('test_eve', row[:type])
      assert_equal("前日の 1 本目。\n2 行あります。", row[:body])
      assert_equal([2026, 11, 3], [row[:year], row[:month], row[:day]])
    end

    # ⚠⚠ **`MM-DD` は「毎年」＝ `year` が NULL。**`YYYY-MM-DD` と混ざっても取り違えない。
    def test_yearly_date_has_no_year
      importer.import(fixture('yearly-test.yaml'))
      row = @repository.dataset[slug: 'test-newyear']

      assert_nil(row[:year])
      assert_equal([1, 1], [row[:month], row[:day]])
    end

    def test_season_is_stored
      importer.import(fixture('yearly-test.yaml'))
      row = @repository.dataset[slug: 'test-autumn']

      assert_equal([9, 10], @repository.seasons(row[:id]))
      assert_nil(row[:month])
    end

    # ⚠⚠ #50 の完了条件。**同じ取り込みを 2 回流しても件数が変わらない。**
    def test_import_is_idempotent
      importer.import(fixture_dir)
      result = importer.import(fixture_dir)

      assert_equal(0, result.created)
      assert_equal(6, result.updated)
      assert_equal(6, @repository.count)
    end

    # ⚠⚠ **旧実装のように毎回クリアして入れ直さない。**変わっていない行は id が動かない。
    def test_import_does_not_clear_and_reinsert
      importer.import(fixture_dir)
      before = @repository.dataset.order(:slug).select_map([:slug, :id])
      importer.import(fixture_dir)

      assert_equal(before, @repository.dataset.order(:slug).select_map([:slug, :id]))
    end

    # 差し替えが効くこと。⚠ 季節も付け替わる（原稿に従属する情報なので）。
    def test_body_is_replaced_on_reimport
      importer.import(fixture('yearly-test.yaml'))
      id = @repository.dataset[slug: 'test-autumn'][:id]
      write_script('replace.yaml', <<~YAML)
        - slug: test-autumn
          type: test_morning
          season: [3]
          body: 春の朝。
      YAML
      importer.import(@tmp_path)

      assert_equal('春の朝。', @repository.dataset[id: id][:body])
      assert_equal([3], @repository.seasons(id))
    end

    # ⚠ 既定では消さない。取り込み元から消えても残る。
    def test_prune_is_off_by_default
      importer.import(fixture_dir)
      write_script('few.yaml', "- slug: test-open\n  type: test_open\n  body: はじまります。\n")
      result = importer.import(@tmp_path)

      assert_nil(result.pruned)
      assert_equal(6, @repository.count)
    end

    def test_prune_removes_disappeared_scripts
      importer.import(fixture_dir)
      write_script('few.yaml', "- slug: test-open\n  type: test_open\n  body: はじまります。\n")
      result = importer.import(@tmp_path, prune: true)

      assert_equal(5, result.pruned.size)
      assert_equal(['test-open'], slugs)
    end

    # ⚠⚠ #50 の完了条件。**`makoto message add` で足した原稿を取り込みが消さない。**
    # slug を持たない行には触らない。
    def test_prune_keeps_messages_without_a_slug
      id = add_by_cli
      importer.import(fixture_dir)
      write_script('few.yaml', "- slug: test-open\n  type: test_open\n  body: はじまります。\n")
      importer.import(@tmp_path, prune: true)

      assert_equal('手で足した原稿', @repository.dataset[id: id][:body])
      assert_equal(2, @repository.count)
    end

    # ⚠⚠ **空の取り込み元を指しても全滅させない。**`--prune` と組み合わさると
    # 「ディレクトリを間違えたら原稿が全部消える」経路になる。
    def test_empty_source_is_rejected
      importer.import(fixture_dir)

      Dir.mktmpdir do |dir|
        assert_raise(Ginseng::ValidateError) {importer.import(dir, prune: true)}
      end

      assert_equal(6, @repository.count)
    end

    def test_missing_path_is_rejected
      assert_raise(Ginseng::ValidateError) {importer.import(File.join(fixture_dir, 'nope'))}
    end

    # ⚠ slug は取り込みの鍵。**重複していたら止める**（後から書いたほうが黙って勝つのを防ぐ）。
    def test_duplicated_slug_is_rejected
      write_script('dup.yaml', <<~YAML)
        - slug: test-dup
          type: test_morning
          body: 1 本目。
        - slug: test-dup
          type: test_morning
          body: 2 本目。
      YAML

      assert_raise(Ginseng::ValidateError) {importer.import(@tmp_path)}
      assert_equal(0, @repository.count)
    end

    def test_missing_slug_is_rejected
      write_script('noslug.yaml', "- type: test_morning\n  body: 名前がない。\n")

      assert_raise(Ginseng::ValidateError) {importer.import(@tmp_path)}
    end

    def test_missing_body_is_rejected
      write_script('nobody.yaml', "- slug: test-empty\n  type: test_morning\n  body: '  '\n")

      assert_raise(Ginseng::ValidateError) {importer.import(@tmp_path)}
    end

    def test_bad_date_is_rejected
      write_script('baddate.yaml', "- slug: test-bad\n  type: test_morning\n  date: '11/4'\n  body: x\n")

      assert_raise(Ginseng::ValidateError) {importer.import(@tmp_path)}
    end

    def test_broken_yaml_is_rejected
      write_script('broken.yaml', "- slug: test\n   type: [\n")

      assert_raise(Ginseng::ValidateError) {importer.import(@tmp_path)}
    end

    # ⚠⚠ **1 件でも駄目なら 1 件も入れない。**半端に入った状態で気付くほうが痛い。
    def test_a_broken_entry_stops_the_whole_import
      write_script('half.yaml', <<~YAML)
        - slug: test-ok
          type: test_morning
          body: 入るはず。
        - slug: test-ng
          type: test_morning
      YAML

      assert_raise(Ginseng::ValidateError) {importer.import(@tmp_path)}
      assert_equal(0, @repository.count)
    end

    # ⚠ 原稿のファイルに Ruby のオブジェクトを書かせない。
    def test_yaml_tags_are_not_loaded
      write_script('tagged.yaml', "- slug: test-tag\n  type: test_morning\n  body: !ruby/object {}\n")

      assert_raise(Ginseng::ValidateError) {importer.import(@tmp_path)}
    end

    # 🔴 **下見の日付も同じ規則で読む**（#96）。⚠⚠ **正本を 3 つ目に増やさない** —
    # `Date.parse` は `11-4` を「11 日」と読み、⚠ **月は実行日の月**になる。
    def test_parse_preview_date_uses_the_same_rule
      today = Date.new(2026, 8, 21)

      assert_equal(Date.new(2026, 11, 4), ScriptImporter.parse_preview_date('2026-11-04', today))
      # ⚠ `MM-DD`（毎年）は実行日の年に補完する。⚠⚠ **8 月に打っても 11 月 4 日。**
      assert_equal(Date.new(2026, 11, 4), ScriptImporter.parse_preview_date('11-4', today))
      assert_equal(Date.new(2027, 11, 4),
        ScriptImporter.parse_preview_date('11-04', Date.new(2027, 1, 1)))
    end

    # 🔴 **ホストの TZ で年を補完しない**（PR #148 の Codex 指摘）。
    # ⚠⚠ **UTC のホストで 12/31 の 15:00 以降は、`Asia/Tokyo` ではもう 1/1。**
    # ⚠ `Date.today` で補完すると **1 年前の 11 月 4 日**を下見する
    # （その年だけの台本 ＝ ライブの本番が引けない）。
    def test_parse_preview_date_fills_the_year_in_the_configured_timezone
      # ⚠ **ホストの TZ が何であっても差が出る瞬間を選ぶ。**UTC-11 を設定に置き、
      # ⚠⚠ **ホスト（JST でも UTC でも）は既に 2027 年・設定の側はまだ 2026-12-31**
      # という時刻で見る。
      config['/scheduler/timezone'] = 'Pacific/Midway'
      Timecop.freeze(Time.utc(2027, 1, 1, 5, 0)) do
        assert_operator(Date.today.year, :>=, 2027, 'ホストの側は既に 2027 年')
        assert_equal(Date.new(2026, 11, 4), ScriptImporter.parse_preview_date('11-4'))
      end
    end

    # ⚠ 空は nil（今日に倒すかは呼ぶ側が決める）。
    def test_parse_preview_date_is_nil_when_empty
      assert_nil(ScriptImporter.parse_preview_date(nil))
      assert_nil(ScriptImporter.parse_preview_date(''))
      assert_nil(ScriptImporter.parse_preview_date('  '))
    end

    # ⚠⚠ **黙って今日に倒さない。**⚠ 後ろのゴミも、形は合っていても存在しない日も弾く。
    def test_parse_preview_date_rejects_a_broken_value
      ['あした', '2026/11/04', '2026/11/04 と 11/5', '13-45', '2026-02-30', '11'].each do |value|
        assert_raise(Ginseng::ValidateError, value) do
          ScriptImporter.parse_preview_date(value)
        end
      end
    end

    private

    # ⚠ 使い捨てのディレクトリに 1 本だけ置く。teardown で消す。
    def write_script(name, body)
      @tmp_path ||= Dir.mktmpdir('makoto-script')
      File.write(File.join(@tmp_path, name), body)
      return @tmp_path
    end

    teardown do
      FileUtils.rm_rf(@tmp_path) if @tmp_path
    end
  end
end
