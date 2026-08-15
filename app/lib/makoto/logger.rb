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
    # ⚠⚠ **キーも見る**（#82 のレビュー指摘）。**値だけ直すと、壊れたキーを持つ
    # Hash がそのまま出口を抜ける。**⚠ **`create_message` は `symbolize_keys` で
    # `to_sym` を呼び、壊れた文字列に対して `EncodingError` を上げる** — そこで
    # ginseng 側の rescue が**渡された Hash を生のまま返す**ので、⚠⚠ **マスクも
    # 掛からないまま syslog まで届く。**
    #
    # ⚠ **例外オブジェクトが素で残る場合がある** — 上と同じ経路で `error:` の値が
    # 例外のまま来る。⚠⚠ **その `to_json` は `to_s` を呼ぶので、ここで潰さないと
    # 同じ場所で落ちる。**
    # ⚠⚠ **`Symbol` も見る。**⚠ **「不正なバイト列の Symbol は作れない」で済ませない** —
    # `String#to_sym` が `EncodingError` を上げるのは**不正なバイト列のときだけ**で、
    # ⚠⚠ **Windows-31J のように「別の符号化として妥当」な文字列は、その符号化を
    # 持ったまま Symbol になれる**（`symbolize_keys` がまさにそれを作る）。**実測で
    # ここだけ落ち残った。**
    #
    # ⚠ **型は変えない**（`Symbol` は `Symbol` のまま）。⚠⚠ **`String` にすると
    # ginseng 側の `mask_fields`（キー名で資格情報を落とす）の見え方が変わる。**
    def scrub(value)
      case value
      when Hash then value.to_h {|key, entry| [scrub(key), scrub(entry)]}
      when Array then value.map {|entry| scrub(entry)}
      when String then value.dup.force_encoding(Encoding::UTF_8).scrub
      when Symbol then scrub(value.to_s).to_sym
      when Exception then "#{value.class}: #{scrub(value.message)}"
      else value
      end
    end
  end
end
