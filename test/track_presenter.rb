module Makoto
  class TrackPresenterTest < TestCase
    def track(**options)
      return {
        name: '〜SONGBIRD〜',
        artist_name: 'キュアソード/剣崎真琴(CV:宮本佳那子)',
        url: 'https://example.test/track/1',
      }.merge(options)
    end

    # ⚠⚠ **画像を添付しない。URL を貼って SNS のプレビューカードに任せる**
    # （→ docs/CLAUDE.md）。本文に出るのは曲名・名義・URL の 3 行だけ。
    def test_song_has_three_lines
      expected = "♪ 〜SONGBIRD〜\nキュアソード/剣崎真琴(CV:宮本佳那子)\nhttps://example.test/track/1"

      assert_equal(expected, TrackPresenter.new(track).to_s)
    end

    # ⚠ カバーは断りを添える。⚠ ゲストコーナーであることが本文だけで分かること。
    def test_cover_carries_the_prefix
      text = TrackPresenter.new(track, prefix: '今日はカバーもやります。').to_s

      assert_equal('今日はカバーもやります。', text.lines.first.chomp)
      assert_includes(text, '♪ 〜SONGBIRD〜')
    end

    # ⚠ 空行を作らない。url が無い曲は母集合から外れているが、ここでも詰める。
    def test_missing_field_does_not_leave_a_blank_line
      text = TrackPresenter.new(track(url: nil)).to_s

      assert_equal(2, text.lines.size)
      assert_not_includes(text, "\n\n")
    end

    def test_blank_prefix_is_ignored
      assert_equal(TrackPresenter.new(track).to_s, TrackPresenter.new(track, prefix: '').to_s)
    end
  end
end
