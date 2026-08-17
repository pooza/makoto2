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

    # ⚠ 資格情報を落とす既定のキー名。⚠⚠ **設定が無いときにここへ倒す** —
    # **マスクしない方向へは倒さない**（設定の不備で秘密が平文に戻るほうが事故が大きい）。
    MASK_FIELDS = [
      'password', 'secret', 'token', 'access_token', 'api_key', 'authorization', 'code'
    ].freeze

    # ⚠ **ログの出口はこの 1 つ。**⚠⚠ **ただし上流が揃えているのは `info` と `error`
    # だけ**なので、⚠ **残りはこちらで通す**（→ 下記）。
    def create_message(src)
      return drop_secrets(scrub(super))
    end

    # 🔴 **`warn` / `debug` / `fatal` を出口に通す**（#97）。
    #
    # ⚠⚠ **`Ginseng::Logger` が上書きしているのは `info` と `error` の 2 つだけ。**
    # ⚠ **残りは `Syslog::Logger` の実装がそのまま走るので、`create_message` を
    # 通らない** — **`drop_secrets` も `scrub` も効かない。**
    #
    # ⚠ **実測**: `warn(post: 'x', token: 'SECRET')` が ⚠⚠ **`token` を平文のまま**
    # 出していた（`info` は落とせている）。⚠ **不正なバイト列の scrub も効かない**ので、
    # **`String#strip` で落ちてログごと消える経路（#79）もここに残っていた。**
    #
    # 🔴 **「出口 1 つに置けば、渡し方の規約を覚えなくてよくなる」（#82）という前提が、
    # `warn` では成立していなかった。**⚠ 現に 5 箇所が `warn` を使っている。
    [:warn, :debug, :fatal].each do |severity|
      define_method(severity) do |message|
        return super(create_message(message).to_json)
      end
    end

    private

    # 🔴 **秘密を出口でもう一度落とす**（#82 のレビュー指摘）。
    #
    # ⚠⚠ **`Ginseng::Logger#create_message` は内部で例外を握ると、渡された Hash を
    # マスクを通さずにそのまま返す。**⚠ **実際に踏むのは `backtrace` を持たない例外**
    # （`error.backtrace.first` が `NoMethodError`）で、⚠⚠ **`raise` していない例外を
    # `error:` に渡すとこの形になる。**
    #
    # 🔴 **しかも #79 の scrub がこれを悪化させた。**⚠ **修正前は syslog の
    # `String#strip` で落ちて「ログごと消えて」いた**が、**scrub で出力できるように
    # なった結果、秘密がそのまま書かれる。**⚠⚠ **「ログが消える」を「秘密が漏れる」に
    # 変えていた**（2026-08-15 実測）。
    #
    # ⚠ **上流の挙動に依存せず、出口で必ず落とす形にする。**
    def drop_secrets(value)
      case value
      when Hash
        value.reject {|key, _| secret?(key)}.transform_values {|entry| drop_secrets(entry)}
      when Array then value.map {|entry| drop_secrets(entry)}
      else value
      end
    end

    def secret?(key)
      return mask_fields.include?(key.to_s.downcase)
    end

    def mask_fields
      @mask_fields ||= (optional_config('/logger/mask_fields') || MASK_FIELDS).to_set do |field|
        field.to_s.downcase
      end
    end

    # ⚠⚠ **入れ子の中まで見る。**落ちるのは `error.message` だけとは限らない —
    # ⚠ **投稿の本文・URL・曲名**も同じ経路でログに載る。
    #
    # ⚠⚠ **キーも見る**（#82 のレビュー指摘）。**値だけ直すと、壊れたキーを持つ
    # Hash がそのまま出口を抜け、syslog の `String#strip` で落ちる。**
    # ⚠ **`to_json` は不正なバイト列をそのまま通す**ので、そこでは止まらない。
    #
    # ⚠ **例外オブジェクトが素で残る場合がある** — 上記の rescue の経路で `error:` の
    # 値が例外のまま来る。⚠⚠ **その `to_json` は `to_s` を呼ぶので、ここで潰さないと
    # 同じ場所で落ちる。**
    # ⚠⚠ **`Symbol` も見る。**⚠ **「不正なバイト列の Symbol は作れない」で済ませない** —
    # `String#to_sym` が `EncodingError` を上げるのは**不正なバイト列のときだけ**で、
    # ⚠⚠ **Windows-31J のように「別の符号化として妥当」な文字列は、その符号化を
    # 持ったまま Symbol になれる**（`symbolize_keys` がまさにそれを作る）。**実測で
    # ここだけ落ち残った。**
    #
    # ⚠ **`symbolize_keys` そのものは壊れたキーで落ちない**（ActiveSupport が
    # `key.to_sym rescue key` で握る）。**キーが原因でマスクが飛ぶことは無い。**
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
