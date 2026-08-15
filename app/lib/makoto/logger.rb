module Makoto
  # ログの出口。ginseng-core の実装に、**文字コードの安全網**を 1 枚だけ被せたもの。
  #
  # ⚠⚠ **エラー処理そのものが落ちると、本当のエラーが見えなくなる。**無人で動く
  # ボットではこれが一番たちが悪い（→ docs/CLAUDE.md）。
  #
  # ## ⚠ 何が起きていたか（#79）
  #
  # `Package#error_message`（`force_encoding(UTF_8).scrub`）は**文字列補間の側では
  # 徹底されていた**が、⚠⚠ **`logger.error(error: e)` は通っていなかった** —
  # `Ginseng::Logger#create_message` が `error.message` を**生のまま**埋めるため。
  #
  # ⚠ **不正なバイト列を含む例外を渡すと、ログ出力そのものが例外になる**
  # （`syslog/logger.rb` の `String#strip` で `Encoding::CompatibilityError`）。
  # しかも**両方の rescue を貫通して消える**:
  #
  # ```
  # PostingJob#post の rescue → logger.error が再送出
  #   → Scheduler#tick の rescue → そこでも logger.error が再送出
  #     → rufus の on_error → stderr
  #       → ⚠⚠ bin/makoto_daemon.rb が start/restart で /dev/null に落としている
  # ```
  #
  # ⚠ **ログに 1 行も残らない。**常駐は生き続け、`makoto status` は健全のまま。
  #
  # ## ⚠⚠ 呼び出し側ではなくここで直す理由
  #
  # #79 は「呼び出し側 6 箇所に `error_message` を通す」案だったが、⚠ **それは
  # 7 箇所目が生えた瞬間に破れる。**⚠⚠ **しかも破れても静かに壊れる**（テストが
  # 落ちるのは、その新しい呼び出しに不正なバイト列が来たときだけ）。
  # **出口 1 つに置けば、渡し方の規約を覚えなくてよくなる。**
  #
  # ⚠ **`error_message` は残す。**あちらは**例外を文字列に埋める**ためのもので、
  # ここは**ログに出す**ためのもの。**経路が違う**（`raise "...: #{error_message(e)}"`
  # はログを通らない）。
  class Logger < Ginseng::Logger
    include Package

    # ⚠ **`info` / `error` / `warn` のすべてがここを通る**（ginseng-core 側で
    # `create_message(message).to_json` の形に揃っている）。
    def create_message(src)
      return scrub(super)
    end

    private

    # ⚠⚠ **入れ子の中まで見る。**落ちるのは `error.message` だけとは限らない —
    # ⚠ **投稿の本文・URL・曲名**も同じ経路でログに載る。
    #
    # ⚠ **例外オブジェクトが素で残る場合がある** — `create_message` は内部で
    # 例外を握ると**渡された Hash をそのまま返す**ので、`error:` の値が
    # 例外のまま来る。⚠⚠ **その `to_json` は `to_s` を呼ぶので、ここで潰さないと
    # 同じ場所で落ちる。**
    def scrub(value)
      case value
      when Hash then value.transform_values {|entry| scrub(entry)}
      when Array then value.map {|entry| scrub(entry)}
      when String then value.dup.force_encoding(Encoding::UTF_8).scrub
      when Exception then "#{value.class}: #{scrub(value.message)}"
      else value
      end
    end
  end
end
