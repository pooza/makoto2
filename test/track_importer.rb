module Makoto
  class TrackImporterTest < TestCase
    def test_import_counts
      counts = TrackImporter.new(track_fixture_dir, db: empty_db).exec

      assert_equal(10, counts[:track])
      assert_equal(4, counts[:live])
      # ⚠ 行数と曲数は一致しない。名義違い・盤違いの同一曲があるため。
      assert_equal(7, counts[:unique])
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
      assert_equal(10, db[:track].count)
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
