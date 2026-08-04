module Makoto
  class TrackRepositoryTest < TestCase
    def tracks
      @tracks ||= TrackRepository.new(track_db)
      return @tracks
    end

    def test_count
      assert_equal(12, tracks.count)
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
      assert_equal(10, tracks.linkable.count)
      assert_not_include(tracks.linkable.select_map(:id), 1009)
    end

    # ⚠⚠ ここが #11 / #13 の入口。同じ曲を 2 度出さない。
    def test_distinct_collapses_duplicates
      assert_equal(8, tracks.distinct.count)
      # 代表は id の小さいほう。
      assert_include(tracks.distinct.select_map(:id), 1001)
      assert_not_include(tracks.distinct.select_map(:id), 1002)
    end

    # ⚠⚠ **順序が効く。**代表（id 最小）だけ url が無い曲は、先に代表を選ぶと
    # `linkable` で曲ごと落ちる。⚠ 先に `linkable` してから代表を選べば、url のある
    # 行が代表になって残る（→ #43）。
    def test_distinct_after_linkable_keeps_the_song
      dropped = tracks.linkable(tracks.distinct).select_map(:id)
      kept = tracks.distinct(tracks.linkable).select_map(:id)

      assert_not_include(dropped, 1011)
      assert_not_include(dropped, 1012)
      assert_include(kept, 1012)
      assert_not_include(kept, 1011)
    end

    def test_distinct_within_live
      assert_equal(2, tracks.distinct(tracks.live).count)
    end

    # ⚠⚠ 行数と曲数を取り違えない。ライブの枠が埋まるかは曲数で見る。
    def test_dedupe_key_count_differs_from_row_count
      assert_equal(12, tracks.count)
      assert_equal(8, tracks.dedupe_key_count)
      assert_equal(4, tracks.live.count)
      assert_equal(2, tracks.dedupe_key_count(tracks.live))
    end

    def test_count_by_kind
      assert_equal(
        {'vocal' => 5, 'bgm' => 2, 'karaoke' => 3, 'tv_size' => 1, 'instrumental' => 1},
        tracks.count_by_kind,
      )
    end

    def test_count_by_kind_within_live
      assert_equal({'vocal' => 4}, tracks.count_by_kind(tracks.live))
    end
  end
end
