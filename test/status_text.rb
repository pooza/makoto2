require 'test/unit'

module Makoto
  # 🔴 **本文の無毒化は上流が持つ**（#327・2026-09-20）。⚠ **`Makoto::StatusText` は
  # 畳んだ**ので、ここに実装は無い。
  #
  # ⚠⚠ **このテストが守るのは「引いている gem がこの性質を持ち続けること」** —
  # ⚠ **上流が `escape_sigils` を組み替えて `H@ppy Together!!!` を壊す形へ戻れば、
  # 黙って本文が変わるのではなく、ここが赤くなる**（#282 / #349 で採ったのと同じ置き方）。
  #
  # 🔴 **当てているのは `escape_sigils`**（`escape_status` ＝ `sanitize_status` ではない）
  # — ⚠⚠ **あちらは HTML の剥がしと `strip` まで含む**ので、**組み上げた本文に当てると
  # 末尾の改行が落ちる。**
  class StatusTextTest < TestCase
    def escape(text)
      return Ginseng::Fediverse::Service.escape_sigils(text)
    end

    # 🔴 **実データで当たる唯一の形**（曲名 7 行・`#キボウレインボウ#`）。
    # ⚠ **本文は `♪ ` に続くので、`#` の直前は空白。**
    def test_escapes_a_hashtag_at_the_head_of_a_title
      assert_equal('♪ # キボウレインボウ#', escape('♪ #キボウレインボウ#'))
    end

    # ⚠⚠ **末尾の `#` は直前が語中文字なので当たらない**（投稿先の `HASHTAG_RE` は
    # 行頭か空白の直後だけを見る）。⚠ **要らない区切りを入れない。**
    def test_leaves_a_hashtag_in_the_middle_of_a_word
      assert_equal('♪ ABC#DEF', escape('♪ ABC#DEF'))
    end

    # 🔴 **かつて `escape_status` を使えなかった理由そのもの。**⚠⚠ **実データの `@` は
    # 曲名 12 行・アルバム名 8 行あり、すべてこの形。**⚠ **v3.0.0 で上流が直した。**
    def test_leaves_an_at_sign_inside_a_word
      assert_equal('♪ H@ppy Together!!!', escape('♪ H@ppy Together!!!'))
    end

    def test_escapes_a_mention
      assert_equal('@ pooza さん', escape('@pooza さん'))
    end

    # ⚠ **後続が ASCII の英数字でなければメンションにならない**（投稿先の
    # `USERNAME_RE` は `[a-z0-9_]` 始まり）。
    def test_leaves_an_at_sign_before_japanese
      assert_equal('値段は@ではない', escape('値段は@ではない'))
    end

    # 🔴 **アルバム名と名義は行頭に来る**ので、**行頭の `#` も当たる。**
    # ⚠⚠ **欄ごとではなく組み上げた本文に当てる理由がこれ。**
    def test_escapes_a_hashtag_at_the_head_of_a_line
      assert_equal("♪ うた\n# アルバム", escape("♪ うた\n#アルバム"))
    end

    # ⚠ **全角 `＃` も投稿先が拾う**。🔴 **全角へ寄せる案が使えない理由。**
    # ⚠⚠ **置換は元の印をそのまま残す**（半角へ寄せると本文を書き換えることになる）。
    def test_escapes_a_full_width_hashtag
      assert_equal('♪ ＃ キボウレインボウ', escape('♪ ＃キボウレインボウ'))
    end

    # ⚠ **URL は無傷**（`#` も `@` も入っていないが、入っても直前が語中文字か `/`）。
    def test_leaves_a_url_alone
      url = 'https://music.apple.com/jp/album/foo/496784719?i=496784721&uo=4'

      assert_equal(url, escape(url))
    end

    def test_is_a_no_op_for_an_empty_string
      assert_equal('', escape(''))
    end

    # 🔴 **末尾の改行を落とさない。**⚠⚠ **`escape_status`（＝ `sanitize_status`）へ
    # 返せなかったのはここ** — ⚠ **あちらは `strip` するので、組み上げた本文の形が変わる。**
    def test_keeps_surrounding_newlines
      assert_equal("♪ うた\n", escape("♪ うた\n"))
    end
  end
end
