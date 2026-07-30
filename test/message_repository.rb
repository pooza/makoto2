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
        {'morning' => 2, 'holiday' => 1, 'birthday' => 1, 'template' => 1},
        @repository.count_by_type,
      )
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
      assert_equal([2001, 2005], @repository.undated.select_map(:id).sort)
      assert_equal([2001], @repository.undated(type: :morning).select_map(:id))
    end
  end
end
