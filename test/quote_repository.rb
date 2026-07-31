module Makoto
  class QuoteRepositoryTest < TestCase
    def setup
      @repository = QuoteRepository.new(corpus_db)
    end

    # 完了条件の本体。**応答に使ってよい台詞だけが引ける**こと。
    # 投稿専用（exclude_respond）と完全封印（exclude）が混ざったら、
    # 人手で付けた判断がまるごと無効になる。
    def test_respondable_excludes_sealed_quotes
      ids = @repository.respondable.select_map(:id).sort

      assert_equal([1001, 1002, 1005], ids)
    end

    def test_respondable_count
      assert_equal(3, @repository.respondable_count)
      assert_equal(5, @repository.count)
    end

    # 変身前後で口調が違うので、ペルソナごとに引けること。
    def test_respondable_by_form_name
      assert_equal([1002], @repository.respondable(form: '剣崎真琴').select_map(:id))
      assert_equal([1001], @repository.respondable(form: 'キュアソード').select_map(:id))
    end

    def test_respondable_by_form_id
      assert_equal([1001], @repository.respondable(form: 1).select_map(:id))
    end

    # ⚠ 「守っているつもりで無防備」を防ぐ正テスト。綴りを間違えた form を
    # 黙って無視すると、**絞り込まれずに全件が応答対象になる**。
    def test_unknown_form_raises
      assert_raise(Ginseng::NotFoundError) {@repository.respondable(form: '剣崎まこと')}
    end

    def test_respondable_by_series
      assert_equal([1005], @repository.respondable(series: 3).select_map(:id))
    end

    # priority は抽選の重み。降順で、同点は id 順に安定すること。
    def test_by_priority
      assert_equal([1001, 1005, 1002], @repository.by_priority.select_map(:id))
    end

    def test_forms
      assert_equal({'キュアソード' => 1, '剣崎真琴' => 2, 'ちびキュアソード' => 3}, @repository.forms)
    end

    # ⚠ **このクラスは `setup` を定義していて `super` を呼んでいない。**それでも
    # 通信が遮断されていることを見る。遮断を `setup` メソッドに置くと、この書き方を
    # した瞬間に無言で素通しになる（TestCase はコールバックで登録している）。
    def test_net_connect_is_blocked_without_super
      assert_raise(WebMock::NetConnectNotAllowedError) do
        Net::HTTP.get(URI.parse('https://example.com/'))
      end
    end
  end
end
