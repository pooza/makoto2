module Makoto
  class TrackLotteryTest < TestCase
    # ⚠ 分布を見るテストは乱数に依存する。シードを固定しないと落ちたり通ったりする。
    def lottery(seed = 20_261_104)
      return TrackLottery.new(TrackRepository.new(track_db), random: Random.new(seed))
    end

    def draws(count, lottery = lottery())
      return Array.new(count) {lottery.draw}
    end

    def test_draw_returns_a_track
      track = lottery.draw

      assert_not_nil(track)
      assert_not_nil(track[:name])
      assert_not_nil(track[:url])
    end

    # ⚠ 曲紹介はリンク付きで曲そのものを出すので、url が無い行は引かない。
    def test_never_draws_rows_without_url
      ids = draws(200).map {|track| track[:id]}

      assert_not_include(ids, 1009)
    end

    # ⚠⚠ 同じ曲の別名義行を引かない。distinct の上で抽選する。
    def test_never_draws_duplicate_representations
      ids = draws(200).map {|track| track[:id]}.uniq

      assert_include(ids, 1001)
      assert_not_include(ids, 1002)
      assert_not_include(ids, 1004)
    end

    # ⚠⚠ この Issue の核心。一様に引くと BGM だらけになるので、そうならないこと。
    def test_bgm_does_not_dominate
      kinds = draws(1000).map {|track| track[:kind]}
      bgm = kinds.count('bgm') / 1000.0
      vocal = kinds.count('vocal') / 1000.0

      assert_operator(vocal, :>, bgm)
      assert_operator(bgm, :<, 0.3)
    end

    # 重みは「選ばれる確率の比」。vocal 10 / bgm 2 なら vocal が約 5 倍。
    #
    # ⚠ 母集合に居ない kind（fixture では instrumental が url 欠けで落ちる）は分母から
    # 外れる。期待値は「実際に引ける kind の重みの合計」で割る。
    def test_distribution_follows_weights
      available = lottery.candidates.distinct.select_map(:kind)
      pool = lottery.weights.slice(*available)
      total = pool.values.sum.to_f
      kinds = draws(2000).map {|track| track[:kind]}

      pool.each do |kind, weight|
        assert_in_delta(weight / total, kinds.count(kind) / 2000.0, 0.05, "kind=#{kind}")
      end
    end

    # ⚠ 曲数の偏りに引きずられないこと。fixture では bgm の代表が 1 曲しか無いのに、
    # 重みどおり bgm が出る。
    def test_weights_are_independent_of_track_counts
      kinds = draws(1000).map {|track| track[:kind]}

      assert_operator(kinds.count('bgm'), :>, 0)
      assert_equal(0, kinds.count('instrumental'))
    end

    # ⚠ 母集合に居ない kind は選ばれない。引き直しでループしないこと。
    def test_skips_kinds_with_no_tracks
      records = TrackRepository.new(track_db).by_kind(:vocal)
      kinds = Array.new(50) {lottery.draw(records)}.map {|track| track[:kind]}

      assert_equal(['vocal'], kinds.uniq)
    end

    def test_draw_returns_nil_for_empty_pool
      records = TrackRepository.new(track_db).by_kind(:nothing)

      assert_nil(lottery.draw(records))
    end

    # ⚠ 同じシードなら同じ結果。テストが再現すること。
    def test_draw_is_reproducible_with_seed
      assert_equal(draws(20, lottery(1)).map {|t| t[:id]}, draws(20, lottery(1)).map {|t| t[:id]})
    end

    def test_weights_come_from_config
      assert_equal(config.keys('/track/weight').map(&:to_s).sort, lottery.weights.keys.sort)
      assert_equal(10, lottery.weights['vocal'])
    end

    # ⚠ 設定の誤りは「静かに何も引けない」ではなく例外にする。
    def test_rejects_all_zero_weights
      config.keys('/track/weight').each {|kind| config["/track/weight/#{kind}"] = 0}

      assert_raise(Ginseng::ConfigError) {lottery.draw}
    end

    def test_rejects_negative_weight
      config['/track/weight/vocal'] = -1

      assert_raise(Ginseng::ConfigError) {lottery.draw}
    end
  end
end
