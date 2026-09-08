require 'test/unit'

module Makoto
  class StatusTextTest < TestCase
    # 🔴 **実データで当たる唯一の形**（曲名 7 行・`#キボウレインボウ#`）。
    # ⚠ **本文は `♪ ` に続くので、`#` の直前は空白。**
    def test_escapes_a_hashtag_at_the_head_of_a_title
      assert_equal('♪ # キボウレインボウ#', StatusText.escape_unintended('♪ #キボウレインボウ#'))
    end

    # ⚠⚠ **末尾の `#` は直前が語中文字なので当たらない**（投稿先の `HASHTAG_RE` は
    # 行頭か空白の直後だけを見る）。⚠ **要らない区切りを入れない。**
    def test_leaves_a_hashtag_in_the_middle_of_a_word
      assert_equal('♪ ABC#DEF', StatusText.escape_unintended('♪ ABC#DEF'))
    end

    # 🔴 **これを壊さないためだけに `escape_status` を使っていない。**
    # ⚠⚠ **実データの `@` は曲名 12 行・アルバム名 8 行あり、すべてこの形。**
    def test_leaves_an_at_sign_inside_a_word
      assert_equal('♪ H@ppy Together!!!', StatusText.escape_unintended('♪ H@ppy Together!!!'))
    end

    def test_escapes_a_mention
      assert_equal('@ pooza さん', StatusText.escape_unintended('@pooza さん'))
    end

    # ⚠ **後続が ASCII の英数字でなければメンションにならない**（投稿先の
    # `USERNAME_RE` は `[a-z0-9_]` 始まり）。
    def test_leaves_an_at_sign_before_japanese
      assert_equal('値段は@ではない', StatusText.escape_unintended('値段は@ではない'))
    end

    # 🔴 **アルバム名と名義は行頭に来る**ので、**行頭の `#` も当たる。**
    # ⚠⚠ **欄ごとではなく組み上げた本文に当てる理由がこれ。**
    def test_escapes_a_hashtag_at_the_head_of_a_line
      assert_equal("♪ うた\n# アルバム", StatusText.escape_unintended("♪ うた\n#アルバム"))
    end

    # ⚠ **全角 `＃` も投稿先が拾う**（`[#＃]`）。🔴 **全角へ寄せる案が使えない理由。**
    def test_escapes_a_full_width_hashtag
      assert_equal('♪ ＃ キボウレインボウ', StatusText.escape_unintended('♪ ＃キボウレインボウ'))
    end

    # ⚠ **URL は無傷**（`#` も `@` も入っていないが、入っても直前が語中文字か `/`）。
    def test_leaves_a_url_alone
      url = 'https://music.apple.com/jp/album/foo/496784719?i=496784721&uo=4'

      assert_equal(url, StatusText.escape_unintended(url))
    end

    def test_is_a_no_op_for_blank
      assert_equal('', StatusText.escape_unintended(''))
      assert_nil(StatusText.escape_unintended(nil))
    end
  end
end
