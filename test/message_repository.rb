module Makoto
  class MessageRepositoryTest < TestCase
    def setup
      @repository = MessageRepository.new(corpus_db)
    end

    def test_by_type
      assert_equal([2001, 2002], @repository.by_type(:morning).select_map(:id).sort)
      assert_equal([2003], @repository.by_type('holiday').select_map(:id))
    end

    def test_count_by_type
      assert_equal(
        {'morning' => 2, 'holiday' => 1, 'birthday' => 2, 'template' => 1},
        @repository.count_by_type,
      )
    end

    # ⚠ 朝挨拶は holiday の原稿でも上書きされる。引く側が type をまとめて指定できること。
    def test_by_type_accepts_multiple
      types = ['morning', 'holiday']

      assert_equal([2001, 2002, 2003], @repository.by_type(types).select_map(:id).sort)
    end

    # 特定日の原稿。旧データで日付を持つのは holiday だけ。
    def test_on_date
      assert_equal([2003], @repository.on_date(1, 1).select_map(:id))
      assert_empty(@repository.on_date(1, 2).select_map(:id))
    end

    def test_on_date_with_type
      assert_empty(@repository.on_date(1, 1, type: :morning).select_map(:id))
    end

    # 季節の原稿。json を解かずに月で引けること。
    def test_in_season
      assert_equal([2002], @repository.in_season(7).select_map(:id))
      assert_equal([2004], @repository.in_season(9).select_map(:id))
      assert_empty(@repository.in_season(5).select_map(:id))
    end

    def test_in_season_with_type
      assert_equal([2002], @repository.in_season(7, type: :morning).select_map(:id))
      assert_empty(@repository.in_season(9, type: :morning).select_map(:id))
    end

    # ⚠ 通年で回してよい原稿だけ。季節指定を持つものが混ざると、
    # 朝挨拶 237 件を通年で回したときに季節外れが出る。
    def test_undated
      assert_equal([2001, 2005, 2006], @repository.undated.select_map(:id).sort)
      assert_equal([2001], @repository.undated(type: :morning).select_map(:id))
    end

    # ⚠⚠ 年指定。旧データ 388 件はすべて NULL ＝ 毎年効くので、年を指定すると
    # 当たらないこと。台本（#13 / #14）はここに入る。
    def test_on_date_with_year
      assert_empty(@repository.on_date(1, 1, year: 2026).select_map(:id))
      id = @repository.create(type: 'live', body: '予告です', year: 2026, month: 11, day: 1)

      assert_equal([id], @repository.on_date(11, 1, year: 2026).select_map(:id))
      # ⚠ 年指定の原稿は「毎年」の段には出てこない。
      assert_empty(@repository.on_date(11, 1).select_map(:id))
    end

    # ⚠ 書き間違えた台本を SQL で直させないための口（CLI の remove）。
    def test_delete
      id = @repository.create(type: 'live', body: '消す原稿', seasons: [9])
      @repository.delete(id)

      assert_nil(@repository.dataset[id: id])
      # 季節の行も一緒に落ちること（外部キーの cascade）。
      assert_empty(@repository.seasons(id))
    end

    def test_create_with_seasons
      id = @repository.create(type: 'morning', body: '秋です', seasons: [9, 10])

      assert_include(@repository.in_season(9).select_map(:id), id)
      assert_include(@repository.in_season(10).select_map(:id), id)
      # ⚠ 季節を持つ原稿は「無指定」に混ざらない（通年で回すと季節外れが出る）。
      assert_not_include(@repository.undated.select_map(:id), id)
    end
  end
end
