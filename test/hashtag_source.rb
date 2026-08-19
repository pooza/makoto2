module Makoto
  class HashtagSourceTest < TestCase
    # 呼ばれたら決まった値を返すだけの `source`。
    class Stub
      def initialize(value)
        @value = value
      end

      def call(time = nil)
        return @value
      end
    end

    def source(value, hashtag: '#TAG')
      return HashtagSource.new(source: Stub.new(value), hashtag: hashtag)
    end

    # ⚠⚠ **最終行をハッシュタグだけの行にする**（Mastodon の仕様。⚠ **タグ直前の
    # 空行はモロヘイヤが入れる**ので、ここでは足さない → #124）。
    def test_appends_the_hashtag_as_its_own_line
      assert_equal("本文\n#TAG", source('本文').call)
      assert_equal('#TAG', source('本文').call.lines.last)
    end

    # ⚠ 複数行の本文でも、最後の 1 行として足す。
    def test_keeps_the_body_intact
      assert_equal("1 行目\n2 行目\n#TAG", source("1 行目\n2 行目").call)
    end

    # ⚠ 本文の末尾に改行があってもタグだけの行にする（空行を挟まない）。
    def test_does_not_leave_a_blank_line
      assert_equal("本文\n#TAG", source("本文\n").call)
      assert_equal("本文\n#TAG", source("本文  \n\n").call)
    end

    # ⚠⚠ **本文が無ければタグも出さない。**nil は「その枠は投稿しない」の合図で、
    # ⚠ ここでタグを足すと**タグだけの投稿が毎日出る**（原稿が無い日・ライブ当日
    # でない日に効く）。
    def test_says_nothing_when_the_body_is_empty
      assert_nil(source(nil).call)
      assert_equal('', source('').call)
      assert_equal("\n", source("\n").call)
    end

    # ⚠ 設定が空なら何もしない。**設定を消せば止まる**ので機能のフラグを持たない。
    def test_is_a_no_op_without_a_hashtag
      assert_equal('本文', source('本文', hashtag: nil).call)
      assert_equal('本文', source('本文', hashtag: '  ').call)
    end

    # 🔴 **本文に既に同じタグがあれば足さない**（`TagContainer` に任せた本体・#124）。
    # ⚠⚠ **原稿の側にタグを書いた枠でタグが 2 つ並ばない。**
    def test_does_not_repeat_a_tag_already_in_the_body
      assert_equal('本文 #TAG', source('本文 #TAG').call)
      assert_equal("本文\n#TAG", source("本文\n#TAG").call)
    end

    # ⚠ **途中まで同じなだけの語は別物。**`#TAGGED` があっても `#TAG` は足す。
    def test_matches_the_whole_tag
      assert_equal("本文 #TAGGED\n#TAG", source('本文 #TAGGED').call)
    end

    # ⚠ 設定の書き方を吸収する。`#` の付け忘れも、語中の空白も同じ形になる。
    def test_normalizes_the_configured_tag
      assert_equal("本文\n#TAG", source('本文', hashtag: 'TAG').call)
      assert_equal(
        "本文\n#SONGBIRD_PARTY_2026",
        source('本文', hashtag: 'SONGBIRD PARTY 2026').call,
      )
    end

    # ⚠⚠ **ASCII-8BIT の本文でも落ちない**（#124）。⚠ `TagContainer#text=` は NFKC を
    # 通すので、素で渡すと `Encoding::CompatibilityError` になる。⚠⚠ **PostingJob の
    # rescue に飲まれて枠が落ちる** ＝ **タグを足す都合で投稿そのものを失う。**
    def test_survives_a_binary_body
      body = '本文'.dup.force_encoding(Encoding::ASCII_8BIT)

      assert_equal('#TAG', source(body).call.lines.last)
    end

    # ⚠ 枠の頭の時刻はそのまま渡す。
    def test_passes_the_slot_through
      stub = Object.new
      def stub.call(time = nil)
        return time.to_s
      end
      subject = HashtagSource.new(source: stub, hashtag: '#TAG')

      assert_equal("2026-11-04\n#TAG", subject.call('2026-11-04'))
    end
  end
end
