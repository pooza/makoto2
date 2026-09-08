module Makoto
  class CorpusImporterTest < TestCase
    # ⚠ 既定の設定では `morning` / `holiday` は取り込まない（正本が移った → #224）。
    def test_counts
      counts = CorpusImporter.new(corpus_fixture_dir, db: empty_db).exec

      assert_equal(3, counts[:form])
      assert_equal(3, counts[:series])
      assert_equal(5, counts[:quote])
      assert_equal(3, counts[:respondable])
      assert_equal(3, counts[:message])
      assert_equal(2, counts[:message_season])
    end

    # ⚠ 移送前の形（`/message/scripted_types` が空）では従来どおり全部入る。
    def test_counts_before_the_migration
      counts = CorpusImporter.new(corpus_fixture_dir, db: corpus_db).exec

      assert_equal(6, counts[:message])
      assert_equal(5, counts[:message_season])
    end

    # 🔴 **正本が `makoto-scripts` へ移った type は旧ダンプから取り込まない**（#224）。
    # ⚠⚠ **これが無いと、`makoto corpus import` を流すたびに旧 237 件が戻る** —
    # ⚠ **足しても落ちない状態**（#212 と同じ形）。
    def test_the_scripted_types_are_not_imported
      db = empty_db
      CorpusImporter.new(corpus_fixture_dir, db: db).exec

      assert_equal(['live_open', 'template'], db[:message].select_map(:type).uniq.sort)
    end

    # 🔴 **旧ダンプ由来（`slug` 無し）の行は消す。**⚠⚠ **ファイル由来（`slug` 有り）
    # には触らない** — **移送した原稿と、あとから足した原稿がそこに居る。**
    def test_the_scripted_types_purge_only_the_rows_without_a_slug
      db = corpus_db
      kept = db[:message].insert(slug: 'morning-0001', type: 'morning', body: 'ファイル由来の原稿')
      config['/message/scripted_types'] = ['morning', 'holiday']
      CorpusImporter.new(corpus_fixture_dir, db: db).exec

      assert_equal('ファイル由来の原稿', db[:message][id: kept][:body])
      assert_empty(db[:message].where(type: 'morning', slug: nil).all)
      assert_empty(db[:message].where(type: 'holiday').all)
    end

    # 🔴 **`birthday` は取り込まない**（#60）。⚠⚠ **用途をライブの台本が吸収した** —
    # 11/4 は 8 時間のライブ当日で、⚠ 旧 `birthday` は進行を持たない静的な宣言。
    # ⚠ **`morning` / `holiday` / `template` は従来どおり入る**（落としすぎない）。
    def test_birthday_is_not_imported
      db = corpus_db
      CorpusImporter.new(corpus_fixture_dir, db: db).exec

      assert_empty(db[:message].where(type: 'birthday').all)
      assert_equal(['holiday', 'live_open', 'morning', 'template'],
        db[:message].select_map(:type).uniq.sort)
    end

    # 🔴 **既に入っている `birthday` も消えること**（#60）。⚠⚠ **稼働中の箱の DB には
    # 既に 23 件が入っている**ので、取り込まないだけでは残り続ける。
    def test_birthday_is_purged_from_an_existing_database
      db = corpus_db
      # ⚠ **`MessageRepository#create` は `birthday` を拒む**ので、直に入れる
      # （＝ #60 より前の投入で入った行を再現する）。
      id = db[:message].insert(type: 'birthday', body: '古い誕生日の原稿')

      assert_equal('古い誕生日の原稿', db[:message][id: id][:body])
      CorpusImporter.new(corpus_fixture_dir, db: db).exec

      assert_nil(db[:message][id: id])
    end

    # ⚠ 何度実行しても同じ結果になること。投入は運用操作で、途中で失敗したら
    # そのまま流し直す。行が増えたり二重になったりしては使えない。
    def test_import_is_idempotent
      importer = CorpusImporter.new(corpus_fixture_dir, db: empty_db)
      first = importer.exec
      second = importer.exec

      assert_equal(first, second)
    end

    # 人手のメタ情報が資産の本体なので、落とさずに移ること。
    def test_keeps_handwritten_metadata
      quote = corpus_db[:quote][id: 1004]

      assert(quote[:exclude])
      assert(quote[:exclude_respond])
      assert_equal('bad', quote[:emotion])
      assert_equal(1, quote[:priority])
      assert_equal(3, quote[:episode])
    end

    def test_keeps_remark
      assert_equal('備考', corpus_db[:quote][id: 1002][:remark])
    end

    # `message.data` の `{"season": [6,7,8]}` が月ごとの行に展開されること。
    def test_expands_seasons
      months = corpus_db[:message_season].where(message_id: 2002).select_map(:month)

      assert_equal([6, 7, 8], months.sort)
    end

    def test_message_body_is_imported
      assert_equal('テスト用の原稿（元日）', corpus_db[:message][id: 2003][:body])
    end

    # ⚠ 取り込み元で季節が減ったら、古い行が残らないこと。消さずに入れ直すと
    # 「6 月だけ」にしたはずの原稿が 7 月にも出続ける。
    def test_removes_stale_seasons
      db = corpus_db
      db[:message_season].insert(message_id: 2002, month: 11)
      CorpusImporter.new(corpus_fixture_dir, db: db).exec

      assert_equal([6, 7, 8], db[:message_season].where(message_id: 2002).select_map(:month).sort)
    end

    # 出典は cure-api を正本にする。TV シリーズには key を振り、cure-api の
    # `/series` に無い劇場版・オールスターズには振らない。
    def test_maps_cure_api_key
      assert_equal('dokidoki', corpus_db[:series][id: 1][:cure_api_key])
      assert_equal('happiness_charge', corpus_db[:series][id: 2][:cure_api_key])
      assert_nil(corpus_db[:series][id: 3][:cure_api_key])
    end

    # ⚠ var/ はコミットしないので、手元に無い環境が普通にある。黙って 0 件を
    # 投入して「成功」にせず、どのファイルが無いかを言って落ちること。
    def test_missing_source_raises
      importer = CorpusImporter.new(File.join(corpus_fixture_dir, 'nowhere'), db: empty_db)

      error = assert_raise(Ginseng::NotFoundError) {importer.exec}
      assert_include(error.message, 'form.json')
      assert_equal(0, empty_db[:quote].count)
    end

    # ⚠ **エラー処理そのものが落ちないこと。**Sequel / SQLite の例外メッセージは
    # ASCII-8BIT で上がってくるので、台詞（非 ASCII）を含む SQL が失敗すると、
    # `"...: #{e.message}"` の埋め込みが `Encoding::CompatibilityError` になる。
    # 本当のエラーが隠れるうえ、無人で動くボットでは誰も気付けない。
    def test_error_message_is_embeddable
      importer = CorpusImporter.new(corpus_fixture_dir, db: Database.connect('sqlite:/'))
      error = assert_raise(Sequel::DatabaseError) {importer.exec}

      assert_equal(Encoding::ASCII_8BIT, error.message.encoding)
      assert_nothing_raised {"投入できませんでした: #{error_message(error)}"}
      assert_equal(Encoding::UTF_8, error_message(error).encoding)
    end

    # 外部キーが効いていること。⚠ これは `Database.connect` の PRAGMA 行を検証する
    # テストではない（Sequel が既定で ON にするため、PRAGMA を消しても通る）。
    # 見ているのは「この接続で外部キーが効いている」という結果のほう。効いていないと
    # form_id の取り違えが黙って通る。
    def test_foreign_key_is_enforced
      assert_raise(Sequel::ForeignKeyConstraintViolation) do
        corpus_db[:quote].insert(id: 9999, form_id: 999, body: 'だめ')
      end
    end
  end
end
