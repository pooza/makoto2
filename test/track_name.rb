module Makoto
  # 曲名から但し書きを落とす規則（#118）。
  #
  # ⚠⚠ **落とし過ぎと落とし足りないの両方を見る。**⚠ **落とし過ぎると別の曲が
  # 1 曲に寄る**（同名別曲を潰す）ので、**落とさない側のテストのほうが大事。**
  class TrackNameTest < TestCase
    # ⚠ 実データの形（2026-08-19 の当日通しリハーサルで出たもの）。
    def test_brackets_are_dropped
      assert_equal('ねこ ときどき らいおん', TrackName.base('ねこ ときどき らいおん【ひょうげんあそび】'))
      assert_equal('ねこ ときどき らいおん', TrackName.base('ねこ ときどき らいおん (『おかあさんといっしょ』より)'))
      assert_equal('パジャマジャ', TrackName.base('パジャマジャ(光るパジャマCM曲)'))
      assert_equal('おおきいはみがき ちいさいはみがき', TrackName.base('おおきいはみがき ちいさいはみがき[6月]'))
      assert_equal('ありがとうがいっぱい', TrackName.base('ありがとうがいっぱい (映画version)'))
    end

    # ⚠ 全角の括弧も同じ規則で落とす（供給元の表記は揃っていない）。
    def test_fullwidth_brackets_are_dropped
      assert_equal('外したい曲', TrackName.base('外したい曲［７月］'))
      assert_equal('外したい曲', TrackName.base('外したい曲（７月）'))
    end

    # ⚠ 括弧が 2 つ以上でも、途中にあっても落とす。⚠⚠ **落とした跡で語がくっつかない。**
    def test_more_than_one_bracket
      assert_equal('みてて!わたしプリンセス', TrackName.base('みてて!わたしプリンセス(ダンス)【3歳児から】'))
      assert_equal('前 後', TrackName.base('前(と)後'))
    end

    # ⚠ **末尾の版の但し書きは波括りでも落とす**（実データ: `~ロング・バージョン`）。
    def test_trailing_version_note_is_dropped
      assert_equal('キッチンオーケストラ', TrackName.base('キッチンオーケストラ ~ロング・バージョン'))
      assert_equal('夢見るシャンソン人形', TrackName.base('夢見るシャンソン人形 ~日本語バージョン'))
      # ⚠ 括弧を落としたあとに末尾へ来るものも拾う。
      assert_equal(
        'ねこ ときどき らいおん',
        TrackName.base('ねこ ときどき らいおん~ロング・バージョン(おかあさんといっしょ)'),
      )
    end

    # 🔴 **波括りの副題は曲名の一部。**⚠⚠ **波括りというだけで落とすと、別の曲が
    # 1 曲に寄る。**版を指す語があるときだけ落とす。
    def test_subtitles_survive
      assert_equal('〜SONGBIRD〜', TrackName.base('〜SONGBIRD〜'))
      assert_equal('HOLY SWORD〜勇気はキズナ〜', TrackName.base('HOLY SWORD〜勇気はキズナ〜'))
      assert_equal(
        'ガンバランスdeダンス ~夢みる奇跡たち~',
        TrackName.base('ガンバランスdeダンス ~夢みる奇跡たち~'),
      )
      assert_equal('TO BE LOVE ~扉~', TrackName.base('TO BE LOVE ~扉~'))
    end

    # ⚠ **`Forever` の `ver` を版と読まない。**
    def test_version_is_not_matched_inside_a_word
      assert_equal('All for one ~Forever~', TrackName.base('All for one ~Forever~'))
      assert_equal('うた ~Very Merry~', TrackName.base('うた ~Very Merry~'))
    end

    # ⚠ **版の但し書きは末尾のものだけ。**曲名の途中の波括りは触らない。
    def test_version_note_in_the_middle_survives
      name = 'ハピネスたいそう ~ トライ・エヴリシング version ~ ナミナミナ'

      assert_equal(name, TrackName.base(name))
    end

    # ⚠⚠ **落とした結果が空になるなら落とさない**（空の鍵に全部が寄るのを防ぐ）。
    def test_empty_result_falls_back_to_the_original
      assert_equal('(まるごと括弧)', TrackName.base('(まるごと括弧)'))
    end

    def test_blank_is_safe
      assert_equal('', TrackName.base(nil))
      assert_equal('', TrackName.base(''))
    end

    # ⚠ 但し書きの無い曲名は 1 文字も変わらない。
    def test_plain_name_is_untouched
      assert_equal('こころをこめて', TrackName.base('こころをこめて'))
      assert_equal('ぴっちぴち♪しずくちゃん!!', TrackName.base('ぴっちぴち♪しずくちゃん!!'))
    end
  end
end
