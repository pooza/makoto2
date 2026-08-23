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

    # ⚠ **波括りが閉じている形も落とす**（Codex の指摘・PR #129）。⚠⚠ **曲名の途中に
    # 来ることがある**ので、閉じている形だけは末尾に限らない。
    def test_paired_version_note_is_dropped
      assert_equal(
        'We can!! HUGっと! プリキュア',
        TrackName.base('We can!! HUGっと! プリキュア ~ロング・イントロ・バージョン~ (TVサイズ)'),
      )
      assert_equal(
        "Let's! フレッシュプリキュア! for the Movie",
        TrackName.base("Let's! フレッシュプリキュア! ~Hybrid ver.~ for the Movie"),
      )
      assert_equal('友情のハーモニー', TrackName.base('友情のハーモニー ～Strings version～'))
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

    # ⚠⚠ **落とすのは波括りか括弧に入っているものだけ。**⚠ **裸の版表記は曲名の一部**
    # として扱う（実データ: `DANZEN! ふたりはプリキュア ver.Max Heart`）。
    def test_bare_version_word_is_untouched
      assert_equal(
        'DANZEN! ふたりはプリキュア ver.Max Heart',
        TrackName.base('DANZEN! ふたりはプリキュア ver.Max Heart'),
      )
    end

    # ⚠ **波括りが閉じていなければ末尾までが但し書き。**⚠⚠ **曲名の途中で閉じない
    # 波括りは実データに無い**ので、ここは「末尾の但し書き」として畳んでよい。
    def test_unclosed_note_takes_the_rest
      assert_equal('きらきらきらりん・みゅーじかる', TrackName.base('きらきらきらりん・みゅーじかる~ロング・バージョン'))
    end

    # ⚠⚠ **落とした結果が空になるなら落とさない**（空の鍵に全部が寄るのを防ぐ）。
    def test_empty_result_falls_back_to_the_original
      assert_equal('(まるごと括弧)', TrackName.base('(まるごと括弧)'))
    end

    def test_blank_is_safe
      assert_equal('', TrackName.base(nil))
      assert_equal('', TrackName.base(''))
    end

    # ⚠ **表示（#119）は括弧書きだけを落とす。**⚠⚠ **版の但し書きは残す** —
    # **選曲の鍵（`base`）とは落とす範囲が違う。**
    def test_display_drops_brackets_only
      assert_equal('ねこ ときどき らいおん', TrackName.display('ねこ ときどき らいおん【ひょうげんあそび】'))
      assert_equal('パジャマジャ', TrackName.display('パジャマジャ(光るパジャマCM曲)'))
      assert_equal('おおきいはみがき ちいさいはみがき', TrackName.display('おおきいはみがき ちいさいはみがき[6月]'))
      assert_equal(
        'キッチンオーケストラ ~ロング・バージョン',
        TrackName.display('キッチンオーケストラ ~ロング・バージョン'),
      )
    end

    # ⚠ 落とした結果が空になるものは落とさない（`base` と同じ保険）。
    def test_display_keeps_the_original_when_everything_would_go
      assert_equal('(まるごと括弧)', TrackName.display('(まるごと括弧)'))
    end

    # ⚠ **単発は全角**（#120）。⚠⚠ **連なっていないものは 3 つとも全角。**
    def test_a_single_mark_becomes_wide
      assert_equal('スマイル！', TrackName.normalize_marks('スマイル!'))
      assert_equal('サンキュ！は I LOVE YOU', TrackName.normalize_marks('サンキュ!は I LOVE YOU'))
      assert_equal('グルグル・マジ？カル・パスポート', TrackName.normalize_marks('グルグル・マジ?カル・パスポート'))
      assert_equal('ホ！ホ！ホ！', TrackName.normalize_marks('ホ!ホ!ホ!'))
    end

    # ⚠⚠ **連なりは半角のまま。**⚠ `！` と `？` が混ざった連なりも 1 つの連なり。
    def test_a_run_of_marks_becomes_narrow
      assert_equal('いえイェイ!!', TrackName.normalize_marks('いえイェイ!!'))
      assert_equal('ぴっちぴち♪しずくちゃん!!', TrackName.normalize_marks('ぴっちぴち♪しずくちゃん!!'))
      assert_equal('うた!?', TrackName.normalize_marks('うた!?'))
    end

    # ⚠ **1 つの曲名の中で混ざる。**
    def test_marks_can_mix_in_one_name
      assert_equal(
        'We can!! HUGっと！ プリキュア',
        TrackName.normalize_marks('We can!! HUGっと! プリキュア'),
      )
    end

    # ⚠⚠ **全角で入っていても同じ結果になる**（供給元の揺れを吸収する）。
    def test_wide_input_gets_the_same_result
      assert_equal('スマイル！', TrackName.normalize_marks('スマイル！'))
      assert_equal('いえイェイ!!', TrackName.normalize_marks('いえイェイ！！'))
      assert_equal('うた!?', TrackName.normalize_marks('うた！？'))
    end

    def test_names_without_marks_are_untouched
      assert_equal('こころをこめて', TrackName.normalize_marks('こころをこめて'))
      assert_equal('', TrackName.normalize_marks(nil))
    end

    # ⚠ 但し書きの無い曲名は 1 文字も変わらない。
    def test_plain_name_is_untouched
      assert_equal('こころをこめて', TrackName.base('こころをこめて'))
      assert_equal('ぴっちぴち♪しずくちゃん!!', TrackName.base('ぴっちぴち♪しずくちゃん!!'))
    end
  end
end
