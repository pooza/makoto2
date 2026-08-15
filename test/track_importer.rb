require 'tmpdir'

module Makoto
  class TrackImporterTest < TestCase
    def test_import_counts
      counts = TrackImporter.new(track_fixture_dir, db: empty_db).exec

      assert_equal(12, counts[:track])
      assert_equal(4, counts[:live])
      # ⚠ 行数と曲数は一致しない。名義違い・盤違いの同一曲があるため。
      assert_equal(8, counts[:unique])
      assert_equal(2, counts[:live_unique])
    end

    def test_columns_are_mapped
      row = track_db[:track][id: 1001]

      assert_equal('しまうまグルグル', row[:name])
      assert_equal('テスト歌手', row[:artist_name])
      assert_equal('テストアルバム A', row[:collection_name])
      assert_equal(Date.new(2013, 5, 29), row[:release_date])
      assert_equal(108_000, row[:duration])
      assert_equal('https://example.test/track/1001', row[:url])
      assert_equal('vocal', row[:kind])
    end

    # ⚠ 何度実行しても同じ結果になること。id は iTunes の trackId をそのまま使う。
    def test_import_is_idempotent
      db = empty_db
      first = TrackImporter.new(track_fixture_dir, db: db).exec
      second = TrackImporter.new(track_fixture_dir, db: db).exec

      assert_equal(first, second)
      assert_equal(12, db[:track].count)
    end

    # ⚠ ライブ用の定義から外れた曲にフラグが残らないこと。
    def test_live_flag_is_rebuilt
      db = track_db
      db[:track].where(id: 1009).update(live: true)
      TrackImporter.new(track_fixture_dir, db: db).exec

      assert_equal(4, db[:track].where(live: true).count)
      assert_false(db[:track][id: 1009][:live])
    end

    # ⚠ 1 曲の日付が壊れていても投入そのものは通す。
    def test_broken_release_date_does_not_stop_import
      row = track_db[:track][id: 1010]

      assert_nil(row[:release_date])
      assert_equal('日付が壊れている曲', row[:name])
    end

    def test_missing_source
      assert_raise(Ginseng::NotFoundError) do
        TrackImporter.new(File.join(track_fixture_dir, 'nowhere'), db: empty_db).exec
      end
    end

    # ⚠ **訂正表だけを足した一時ディレクトリで見る。**共有のフィクスチャは触らない
    # （曲数を変えると他のテストの前提が動く）。
    def with_corrections(entries)
      Dir.mktmpdir do |dir|
        [TrackImporter::DAILY, TrackImporter::LIVE].each do |name|
          FileUtils.cp(File.join(track_fixture_dir, name), File.join(dir, name))
        end
        File.write(File.join(dir, TrackImporter::CORRECTIONS), entries.to_yaml)
        yield dir
      end
    end

    def correction(id, from, to)
      return {'id' => id, 'from' => from, 'to' => to,
              'noticed' => Date.new(2026, 8, 14), 'reason' => 'テスト'}
    end

    # ⚠ 取り込み中の警告を拾う。**訂正表を片付ける合図が実際に出ること**を見る。
    def import_with_warnings(dir, db)
      importer = TrackImporter.new(dir, db: db)
      warnings = []
      logger = Object.new
      logger.define_singleton_method(:warn) {|message| warnings.push(message)}
      logger.define_singleton_method(:info) {|message| message}
      importer.instance_variable_set(:@logger, logger)
      importer.exec
      return warnings.select {|message| message[:track] == 'correction'}
    end

    # ⚠⚠ **供給元が間違えた曲名を訂正する**（#58）。⚠ **鍵は訂正後の曲名から作る** —
    # 訂正前で作ると重複がたたまれず、ライブの並びで同じ曲が隣接したままになる。
    def test_correction_fixes_the_name_and_the_dedupe_key
      with_corrections([correction(1010, '日付が壊れている曲', 'テスト組曲')]) do |dir|
        db = empty_db
        TrackImporter.new(dir, db: db).exec

        assert_equal('テスト組曲', db[:track][id: 1010][:name])
        assert_equal(db[:track][id: 1009][:dedupe_key], db[:track][id: 1010][:dedupe_key])
      end
    end

    # ⚠⚠ **訂正表に無い曲名は 1 文字も変わらない。**これが無いと、訂正表が
    # 「表記ゆれを一般に吸収する規則」に育ってしまう（別の曲を潰す）。
    def test_untouched_names_are_identical
      with_corrections([correction(1010, '日付が壊れている曲', 'テスト組曲')]) do |dir|
        db = empty_db
        TrackImporter.new(dir, db: db).exec
        expected = track_db[:track].exclude(id: 1010).order(:id).select_map([:id, :name, :dedupe_key])

        assert_equal(expected, db[:track].exclude(id: 1010).order(:id).select_map([:id, :name, :dedupe_key]))
      end
    end

    # ⚠⚠ **`from` が一致しなければ訂正しない。**⚠ 訂正表そのものを見直す合図として
    # 警告を残す。
    def test_correction_is_skipped_when_the_source_changed
      with_corrections([correction(1010, 'もう存在しない曲名', 'テスト組曲')]) do |dir|
        db = empty_db
        warnings = import_with_warnings(dir, db)

        assert_equal('日付が壊れている曲', db[:track][id: 1010][:name])
        assert_equal(1, warnings.size)
        assert_equal('unknown', warnings.first[:state])
      end
    end

    # ⚠⚠ **供給元が直した形（曲名が `to` と一致）でも黙らない**（#72 のレビュー指摘）。
    # ⚠ **上流が直すときの一番ありふれた形がこれ**で、素通しにすると
    # **「この行はもう消せる」という合図が永久に出ない。**
    def test_an_upstream_fix_is_reported_as_obsolete
      with_corrections([correction(1010, 'もう存在しない曲名', '日付が壊れている曲')]) do |dir|
        db = empty_db
        warnings = import_with_warnings(dir, db)

        # ⚠ 曲名は供給元のまま（訂正はしない）。
        assert_equal('日付が壊れている曲', db[:track][id: 1010][:name])
        assert_equal(1, warnings.size)
        assert_equal('fixed', warnings.first[:state])
        assert_equal(1010, warnings.first[:id])
      end
    end

    # ⚠ 訂正が当たっている間は警告を出さない（片付けの合図と混ざらない）。
    def test_an_applied_correction_is_quiet
      with_corrections([correction(1010, '日付が壊れている曲', 'テスト組曲')]) do |dir|
        assert_empty(import_with_warnings(dir, empty_db))
      end
    end

    # ⚠ `makoto track import` を流し直しても訂正が戻らないこと。
    def test_correction_survives_a_reimport
      with_corrections([correction(1010, '日付が壊れている曲', 'テスト組曲')]) do |dir|
        db = empty_db
        TrackImporter.new(dir, db: db).exec
        TrackImporter.new(dir, db: db).exec

        assert_equal('テスト組曲', db[:track][id: 1010][:name])
      end
    end

    # ⚠ 訂正表は無くてもよい（あとから足せる）。
    def test_import_without_a_corrections_file
      assert_false(File.exist?(File.join(track_fixture_dir, TrackImporter::CORRECTIONS)))
      assert_equal(12, TrackImporter.new(track_fixture_dir, db: empty_db).exec[:track])
    end

    # ⚠⚠ 名義違い・盤違いの同一曲が同じ鍵になること。duration は 1〜3 秒ばらつくので
    # 鍵に使えない（実データで確認済み）。
    def test_dedupe_key_merges_duplicates
      db = track_db

      assert_equal(db[:track][id: 1001][:dedupe_key], db[:track][id: 1002][:dedupe_key])
    end

    # ⚠ 全角・空白・記号の揺れを NFKC で吸収すること。実データでも
    # 「プリキュア! カナYell☆ミラクル」と「プリキュア！カナYell☆ミラクル」が出てくる。
    def test_dedupe_key_normalizes_width_and_symbols
      assert_equal(
        TrackImporter.dedupe_key('テストのうた My True Love!'),
        TrackImporter.dedupe_key('テストのうた　Ｍｙ　Ｔｒｕｅ　Ｌｏｖｅ！'),
      )
    end

    def test_dedupe_key_keeps_different_songs_apart
      assert_not_equal(
        TrackImporter.dedupe_key('しまうまグルグル'),
        TrackImporter.dedupe_key('しまうまグルグル (オリジナル・カラオケ)'),
      )
    end
  end
end
