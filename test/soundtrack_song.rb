module Makoto
  # サントラ盤の中の歌を `bgm` から外す規則（#497）。
  class SoundtrackSongTest < TestCase
    # ⚠ 実際の cure-api を叩かない。`歌手` で始まる名義だけを歌手として通す。
    FakeCureApi = Struct.new(:online) do
      def available?
        return online
      end

      def singer?(artist_name)
        return online && artist_name.to_s.start_with?('歌手')
      end
    end

    def rule(online: true)
      return SoundtrackSong.new(cure_api: FakeCureApi.new(online))
    end

    def row(name, artist, kind: 'bgm')
      return {trackName: name, artistName: artist, kind: kind}
    end

    # 🔴 **歌手名義のフルサイズは `vocal`。**
    def test_a_singer_on_a_soundtrack_is_vocal
      assert_equal('vocal', rule.kind(row('鮮烈!キュアモフルン', '歌手A')))
    end

    # 🔴 **短縮版は `tv_size`**（2026-11-05・オーナー判断）。⚠ **「映画version」の類も短縮版。**
    def test_short_versions_are_tv_size
      [
        'テストのうた(映画サイズ)', 'テストのうた (映画 size)', 'テストのうた (TVsize)',
        'テストのうた (Short version)', 'テストのうた ~咲 & 舞version~ (SHORT SIZE EDIT)',
        'テストのうた (Shortサイズ)', 'テストのうた(映画version)', 'テストのうた (劇場Version)',
        'テストのうた(Movie version)', 'テストのうた(映画エンディング主題歌version)'
      ].each do |name|
        assert_equal('tv_size', rule.kind(row(name, '歌手A')), name)
      end
    end

    # ⚠⚠ **版の名前だけでは短縮版にしない**（`キュアスター・ヴァージョン` は全部の歌）。
    # ⚠ **括弧をまたいで「映画 … version」を拾わない。**
    def test_other_versions_stay_vocal
      ['テストのうた (キュアスター・ヴァージョン)', '映画のうた (2013 Version)'].each do |name|
        assert_equal('vocal', rule.kind(row(name, '歌手A')), name)
      end
    end

    # 🔴 **キャラクター名義は、歌手の一覧なしで見分ける。**⚠ **変身バンクの歌は短くても `vocal`**
    # （長さでは切らない・オーナー判断）。
    def test_a_character_credit_is_a_song
      assert_equal('vocal', rule(online: false).kind(row('Trio Dreams', 'キュアアイドル(CV:松岡美里)')))
      assert_equal('vocal', rule(online: false).kind(row('テストのうた', 'キュアスター(CV.成瀬瑛美)')))
    end

    # ⚠⚠ **作曲家の名義は劇伴のまま**（`/singers` に入っていない）。
    def test_a_composer_stays_bgm
      assert_equal('bgm', rule.kind(row('テストのうた -Short Version-', '作曲家A')))
    end

    # ⚠ **`bgm` でない行には触らない。**
    def test_other_kinds_are_untouched
      assert_equal('karaoke', rule.kind(row('テストのうた (TVsize)', '歌手A', kind: 'karaoke')))
      assert_equal('vocal', rule.kind(row('テストのうた (映画サイズ)', '歌手A', kind: 'vocal')))
    end
  end
end
