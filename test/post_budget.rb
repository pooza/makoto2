module Makoto
  # 原稿 1 本に使える本文の長さ（#282）。
  class PostBudgetTest < TestCase
    def budget
      return PostBudget.new
    end

    # 🔴 **URL は長さによらず 23 字**（投稿先と同じ数え方）。
    def test_a_url_counts_as_a_fixed_length
      text = "あいう https://example.com/#{'x' * 100} えお"

      assert_equal(3 + 1 + 23 + 1 + 2, PostBudget.length(text))
    end

    # ⚠⚠ **見た目の 1 文字を 1 字と数える**（Codex の P2）。🔴 **家族の絵文字は 7 コードポイントで 1 字。**
    def test_a_grapheme_cluster_counts_as_one
      family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"

      assert_equal(1, PostBudget.length(family))
      assert_equal(2, PostBudget.length("が\u{3099}#{family}".unicode_normalize(:nfd)))
    end

    # ⚠⚠ **ハッシュタグを外した設定でも取り込みが落ちない**（Codex の P2）。
    def test_the_budget_without_a_hashtag
      config.delete('/live/hashtag')

      assert_equal(config['/mastodon/max_length'], budget.budget('live_mc'))
      assert_equal(budget.budget('song'), PostBudget.new.budget('song'))
    ensure
      config.reload
    end

    # ⚠ **type ごとに、前後に付く定型文を引く。**
    def test_the_budget_depends_on_the_type
      limit = config['/mastodon/max_length']

      assert_equal(limit - PostBudget::TRACK_RESERVE, budget.budget('song'))
      assert_equal(limit - Morning.new.greeting.length - 1, budget.budget('morning'))
      assert_equal(limit - config['/live/hashtag'].length - 1, budget.budget('live_mc'))
      assert_equal(limit, budget.budget('holiday'))
    end

    # ⚠⚠ **種類別の前置きも曲の行を取っておく**（`/song/kind_types`）。
    def test_kind_types_reserve_the_track_line
      Song.new.kind_types.each_value do |type|
        assert_equal(budget.budget('song'), budget.budget(type), type)
      end
    end

    def test_validate
      allowed = budget.budget('morning')

      assert_nothing_raised {budget.validate('morning', 'あ' * allowed, 'ok')}
      assert_raise(Ginseng::ValidateError) {budget.validate('morning', 'あ' * (allowed + 1), 'ng')}
    end
  end
end
