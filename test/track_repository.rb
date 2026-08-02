module Makoto
  class TrackRepositoryTest < TestCase
    def tracks
      @tracks ||= TrackRepository.new(track_db)
      return @tracks
    end

    def test_count
      assert_equal(10, tracks.count)
    end

    def test_live
      assert_equal(4, tracks.live.count)
      assert_equal([1001, 1002, 1003, 1004], tracks.live.order(:id).select_map(:id))
    end

    def test_by_kind
      assert_equal(5, tracks.by_kind(:vocal).count)
      assert_equal(2, tracks.by_kind('bgm').count)
      assert_equal(0, tracks.by_kind(:nothing).count)
    end

    # ⚠ 曲紹介はリンク付きで曲そのものを出すので、url が無い行は使えない。
    def test_linkable_drops_rows_without_url
      assert_equal(9, tracks.linkable.count)
      assert_not_include(tracks.linkable.select_map(:id), 1009)
    end

    # ⚠⚠ ここが #11 / #13 の入口。同じ曲を 2 度出さない。
    def test_distinct_collapses_duplicates
      assert_equal(7, tracks.distinct.count)
      # 代表は id の小さいほう。
      assert_include(tracks.distinct.select_map(:id), 1001)
      assert_not_include(tracks.distinct.select_map(:id), 1002)
    end

    def test_distinct_within_live
      assert_equal(2, tracks.distinct(tracks.live).count)
    end

    # ⚠⚠ 行数と曲数を取り違えない。ライブの枠が埋まるかは曲数で見る。
    def test_dedupe_key_count_differs_from_row_count
      assert_equal(10, tracks.count)
      assert_equal(7, tracks.dedupe_key_count)
      assert_equal(4, tracks.live.count)
      assert_equal(2, tracks.dedupe_key_count(tracks.live))
    end

    def test_count_by_kind
      assert_equal(
        {'vocal' => 5, 'bgm' => 2, 'karaoke' => 1, 'tv_size' => 1, 'instrumental' => 1},
        tracks.count_by_kind,
      )
    end

    def test_count_by_kind_within_live
      assert_equal({'vocal' => 4}, tracks.count_by_kind(tracks.live))
    end
  end
end
