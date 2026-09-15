require 'test/unit'

module Makoto
  # 🔴 **上流（`Ginseng::Fediverse::TagContainer.to_utf8`）に預けた判断を、こちらの
  # 期待として留める**（#280）。
  #
  # ⚠⚠ **`Text.utf8` は 1 行の委譲**なので、**ここで見ているのは上流の振る舞い**。
  # ⚠ **それでよい** — 🔴 **本文が UTF-8 で組めるかどうかは、毎日 4 枠が出るか
  # 出ないかを決めている**ので、**上流が動いたら黙ってずれるのではなく赤くなる
  # ほうがよい**（→ [`ginseng-fediverse#277`](https://github.com/pooza/ginseng-fediverse/issues/277)）。
  class TextTest < TestCase
    # ⚠ **UTF-8 はそのまま。**
    def test_passes_utf8_through
      assert_equal('剣崎真琴', Text.utf8('剣崎真琴'))
      assert_equal(Encoding::UTF_8, Text.utf8('剣崎真琴').encoding)
    end

    # 🔴 **ASCII-8BIT で中身が妥当なら、ラベルだけを剥がす**（1 バイトも変えない）。
    #
    # ⚠⚠ **`Sequel` / SQLite が非 ASCII をこの形で返す**（#124 / #79）ので、
    # **これが #280 で塞ぎたかった本体。**
    def test_relabels_a_valid_binary_string
      source = '剣崎真琴'.dup.force_encoding(Encoding::ASCII_8BIT)

      assert_equal('剣崎真琴', Text.utf8(source))
      assert_equal(Encoding::UTF_8, Text.utf8(source).encoding)
      assert_equal(source.bytes, Text.utf8(source).bytes)
    end

    # ⚠ **名前のある符号化は `encode` する**（🔴 **中身を保つ**）。
    #
    # ⚠⚠ **ラベルの貼り替えではない** — **`'凜々'.encode('Windows-31J')` のバイト列は
    # 妥当な UTF-8 でもある**ので、**貼り替えると `ꣁX` になる**（→ `HashtagSource`）。
    def test_encodes_a_named_encoding
      assert_equal('凜々', Text.utf8('凜々'.encode('Windows-31J')))
      assert_equal(Encoding::UTF_8, Text.utf8('凜々'.encode('Windows-31J')).encoding)
    end

    # 🔴 **寄せられないものは黙って直さない。**⚠⚠ **`scrub` すると化けた本文が
    # 投稿される** — ⚠ **落として `error` を残すほうがよい**（→ `PostingJob#create_text`）。
    def test_rejects_an_invalid_byte_sequence
      assert_raise(Ginseng::ValidateError) {Text.utf8("本文\xE3\x81".dup.force_encoding(Encoding::ASCII_8BIT))}
      assert_raise(Ginseng::ValidateError) {Text.utf8("本文\xE3\x81")}
    end

    # ⚠ **nil は空文字**（→ `TrackPresenter#to_s` の `compact_blank` が行ごと落とす）。
    def test_treats_nil_as_an_empty_string
      assert_equal('', Text.utf8(nil))
    end
  end
end
