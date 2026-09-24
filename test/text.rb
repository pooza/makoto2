require 'test/unit'

module Makoto
  # 🔴 **上流（`Ginseng::Fediverse::Text.to_utf8`）に預けた判断を、こちらの
  # 期待として留める**（#280）。
  #
  # ⚠⚠ **`Text.utf8` は 1 行の委譲**なので、**ここで見ているのは上流の振る舞い**。
  # ⚠ **それでよい** — 🔴 **本文が UTF-8 で組めるかどうかは、毎日 4 枠が出るか
  # 出ないかを決めている**ので、**上流が動いたら黙ってずれるのではなく赤くなる
  # ほうがよい**。
  class TextTest < TestCase
    # 🔴 **応答の `content` を本文へ戻す**（#351）。⚠ **`</p>` は空行、`<br>` は改行。**
    def test_from_html_restores_the_line_breaks
      html = '<p>おはよう<br />真琴です</p><p>またね</p>'

      assert_equal("おはよう\n真琴です\n\nまたね", Text.from_html(html))
    end

    # 🔴 **URL は元の長さで戻る**（⚠⚠ **Mastodon は span に割って入れているだけで、
    # 切り詰めているのは CSS のほう**）。⚠ **戻らないと `proxy_added` が URL のぶん
    # 短く出る。**
    def test_from_html_restores_a_url_split_into_spans
      html = '<p>みてね <a href="https://example.com/very/long/path" rel="nofollow">' \
        '<span class="invisible">https://</span><span class="ellipsis">example.com/very</span>' \
        '<span class="invisible">/long/path</span></a></p>'

      assert_equal('みてね https://example.com/very/long/path', Text.from_html(html))
    end

    # 🔴 **カスタム絵文字は `<img alt=":shortcode:">` で返る**（Codex の P2）。
    # ⚠⚠ **alt を戻さないと、送った側にだけ shortcode が残って `proxy_added` が短く出る。**
    def test_from_html_restores_a_custom_emoji_shortcode
      html = '<p>おはよう <img draggable="false" class="emojione custom-emoji"' \
        ' alt=":precure:" title=":precure:" src="https://st2.precure.ml/e.png"></p>'

      assert_equal('おはよう :precure:', Text.from_html(html))
    end

    # ⚠ **実体参照を戻す**（🔴 **戻さないと `&amp;` が 5 字として数えられる**）。
    def test_from_html_unescapes_entities
      assert_equal('A&B <tag>', Text.from_html('<p>A&amp;B &lt;tag&gt;</p>'))
    end

    # ⚠ **タグの行が足された形**（モロヘイヤが足すのはこれ）。
    def test_from_html_restores_an_appended_tag_line
      html = '<p>こんにちは</p><p><a href="https://st2.precure.ml/tags/precure_fun"' \
        ' class="mention hashtag" rel="tag">#<span>precure_fun</span></a></p>'

      assert_equal("こんにちは\n\n#precure_fun", Text.from_html(html))
    end

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

    # 🔴 **弾いたときは入口の名前がメッセージに残る**（#381 ← `ginseng-fediverse#263`）。
    # ⚠ **渡さなければ付かない**（従来どおり）。
    def test_names_the_entry_when_rejecting
      error = assert_raise(Ginseng::ValidateError) {Text.utf8("本文\xE3\x81", 'MorningSource#call')}
      assert_match(/\(at MorningSource#call\)\z/, error.message)

      error = assert_raise(Ginseng::ValidateError) {Text.utf8("本文\xE3\x81")}
      assert_no_match(/\(at /, error.message)
    end

    # ⚠ **nil は空文字**（→ `TrackPresenter#to_s` の `compact_blank` が行ごと落とす）。
    def test_treats_nil_as_an_empty_string
      assert_equal('', Text.utf8(nil))
    end
  end
end
