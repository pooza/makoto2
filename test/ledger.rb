require 'tmpdir'

module Makoto
  class LedgerTest < TestCase
    SAMPLE = <<~MD.freeze
      # 足した設定の台帳

      ## 決まり

      | 印 | 意味 |
      | --- | --- |
      | 宮本 | 旧 MAKOTO |

      ## 食べ物・飲み物

      | 中身 | 出どころ | 根拠 | 採用 |
      | --- | --- | --- | --- |
      | いちごが大好き | 宮本 | `morning-0010` | 2026-11-09 |
      | きのこが苦手 | 宮本 | `morning-0001` | 2026-11-09 |

      ## 人間関係

      | 中身 | 出どころ | 根拠 | 採用 |
      | --- | --- | --- | --- |
      | 事務所の先輩がいる。⚠ 先輩に名前は付けない | 宮本 | `morning-0052` | 2026-11-09 |

      ## 載せないと決めたもの

      | 中身 | 根拠 | 理由 |
      | --- | --- | --- |
      | 乗馬が特技 | `morning-0009` | 王女の趣味と結びつけない |
    MD

    def setup
      @dir = Dir.mktmpdir
      @path = File.join(@dir, 'ledger.md')
    end

    def teardown
      FileUtils.rm_rf(@dir)
    end

    # 🔴 **渡すのは中身の列だけ**（出どころ・根拠は渡さない）。⚠ 決まりと載せないものの節は渡さない。
    def test_to_prompt
      File.write(@path, SAMPLE)
      text = Ledger.new(@path).to_prompt

      assert_include(text, "## 食べ物・飲み物\n\n- いちごが大好き\n- きのこが苦手")
      assert_include(text, '- 事務所の先輩がいる。 先輩に名前は付けない'.squeeze(' '))
      assert_not_include(text, '乗馬')
      assert_not_include(text, 'morning-')
      assert_not_include(text, '旧 MAKOTO')
      assert_not_include(text, '中身')
    end

    # ⚠ **無ければ渡さない**（手元・CI には makoto-scripts が無いことがある）。
    def test_missing_ledger_is_nil
      assert_nil(Ledger.new(File.join(@dir, 'nothing.md')).to_prompt)
    end
  end
end
