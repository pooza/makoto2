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

    # ⚠ **ライブは曲名の括弧書きを落とす**（#119）。⚠⚠ **落とすかどうかは呼ぶ側が決める** —
    # **日常の曲紹介（#16）では落とさない**（オーナー判断・2026-08-19）。
    def test_plain_name_drops_brackets
      text = TrackPresenter.new(track(name: 'パジャマジャ(光るパジャマCM曲)'), plain_name: true).to_s

      assert_includes(text, '♪ パジャマジャ')
      assert_not_includes(text, '光るパジャマ')
    end

    def test_brackets_survive_by_default
      text = TrackPresenter.new(track(name: 'パジャマジャ(光るパジャマCM曲)')).to_s

      assert_includes(text, '♪ パジャマジャ(光るパジャマCM曲)')
    end

    # ⚠⚠ **感嘆符・疑問符は常に揃える**（#120）。⚠ **こちらはライブ限定ではない。**
    def test_marks_are_normalized_in_both_modes
      assert_includes(TrackPresenter.new(track(name: 'スマイル!')).to_s, '♪ スマイル！')
      assert_includes(
        TrackPresenter.new(track(name: 'いえイェイ!!'), plain_name: true).to_s,
        '♪ いえイェイ!!',
      )
    end

    # 🔴 **名義を出さない形**（#121）。⚠ **行ごと落とす**（空行を作らない）。
    def test_the_credit_can_be_hidden
      text = TrackPresenter.new(track, artist: false).to_s

      assert_equal(2, text.lines.size)
      assert_not_includes(text, 'キュアソード')
      assert_not_includes(text, "\n\n")
    end

    def test_the_credit_is_shown_by_default
      assert_equal('キュアソード/剣崎真琴(CV:宮本佳那子)', TrackPresenter.new(track).credit)
      assert_nil(TrackPresenter.new(track, artist: false).credit)
    end

    # ⚠⚠ **断りの後ろは 1 行アキ**（#122）。⚠ **断りと曲名が地続きだと、断りが曲名の
    # 一部に見える。**
    def test_the_prefix_is_followed_by_a_blank_line
      text = TrackPresenter.new(track, prefix: '今日はカバーもやります。').to_s

      assert_equal(['今日はカバーもやります。', '', '♪ 〜SONGBIRD〜'],
        text.lines.first(3).map(&:chomp))
    end

    # ⚠ 断りが無いとき（本編の曲）に先頭が空行にならないこと。
    def test_without_a_prefix_there_is_no_blank_line
      assert_not_includes(TrackPresenter.new(track).to_s, "\n\n")
    end

    def test_blank_prefix_is_ignored
      assert_equal(TrackPresenter.new(track).to_s, TrackPresenter.new(track, prefix: '').to_s)
    end
  end
end
