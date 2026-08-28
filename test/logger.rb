module Makoto
  # ⚠⚠ **エラー処理そのものが落ちると、本当のエラーが見えなくなる**（#79）。
  # 無人で動くボットではこれが一番たちが悪い。
  class LoggerTest < TestCase
    def logger
      @logger ||= Logger.new
      return @logger
    end

    def raised(message)
      raise Ginseng::GatewayError, message
    rescue => e
      return e
    end

    # ⚠ `wrong status line: "..."` のように**切り詰められたバイト列**を含む形。
    # ⚠⚠ **Sequel / SQLite の例外は ASCII-8BIT でもバイト列は妥当な UTF-8 なので
    # 通る**ので、これが実際に踏む形。
    def broken
      return "wrong status line: \"\xE3\x81\""
    end

    def sjis
      return '真琴'.encode('Windows-31J').dup.force_encoding(Encoding::UTF_8)
    end

    # ⚠⚠ **これが #79 の再現。**⚠ **両方の rescue を貫通して stderr へ抜け、
    # `bin/makoto_daemon.rb` が `/dev/null` に落とすので 1 行も残らなかった。**
    def test_error_with_invalid_bytes_does_not_raise
      assert_nothing_raised {logger.error(post: 'live', error: raised(broken))}
      assert_nothing_raised {logger.error(post: 'live', error: raised(sjis))}
    end

    def test_info_with_invalid_bytes_does_not_raise
      assert_nothing_raised {logger.info(post: 'live', text: broken)}
    end

    # ⚠ **落ちないだけでなく、中身が残ること。**握り潰して空行を出すのでは意味が無い。
    def test_the_message_survives
      message = logger.create_message(post: 'live', error: raised(broken))

      assert_equal('live', message[:post])
      assert_include(message[:error][:message], 'wrong status line')
      assert_nothing_raised {message.to_json}
    end

    # ⚠⚠ **入れ子の中まで見る。**落ちるのは `error.message` だけとは限らない —
    # ⚠ **投稿の本文・URL・曲名**も同じ経路でログに載る。
    #
    # 🔴 **見るのは `create_entry`**（#101 で上流へ返した）。⚠⚠ **`create_message` は
    # マスクするだけで scrub はしない** — **不正なバイト列を落とすのは出口の側。**
    def test_nested_values_are_scrubbed
      entry = logger.create_entry(track: {name: broken, artists: [broken]})

      assert_true(entry.valid_encoding?)
      assert_include(entry, '_encoding_error')
    end

    # ⚠⚠ **キーも見る**（#82 のレビュー指摘）。⚠ **値だけ直すと、壊れたキーを持つ
    # Hash がそのまま出口を抜ける。**
    #
    # ⚠ **`create_message` は `symbolize_keys` で `to_sym` を呼ぶ** — 不正なバイト列なら
    # `EncodingError` を上げ、ginseng 側の rescue が**渡された Hash を生のまま返す**
    # （⚠⚠ **マスクも掛からない**）。**落ちるのは `to_json` ではなく、その先の
    # syslog（`String#strip`）。**
    def test_string_keys_are_scrubbed
      assert_nothing_raised {logger.info(context: {broken => 'value'})}
      assert_nothing_raised {logger.info(context: [{broken => 'value'}])}
    end

    # ⚠⚠ **「不正なバイト列の Symbol は作れない」で済ませない。**`String#to_sym` が
    # `EncodingError` を上げるのは**不正なバイト列のときだけ**で、⚠ **Windows-31J の
    # ように「別の符号化として妥当」な文字列は、その符号化を持ったまま Symbol になれる**
    # （`symbolize_keys` がまさにそれを作る）。⚠ **実測でここだけ落ち残った。**
    def test_keys_valid_in_another_encoding_are_scrubbed
      assert_nothing_raised {logger.info(context: {'真琴'.encode('Windows-31J') => 'value'})}
    end

    # ⚠ **文字列のキーでもマスクが効くこと。**
    #
    # ⚠⚠ **以前は「キーの型を変えない」ことを担保していた**（こちらの `scrub` が
    # `Symbol` を `Symbol` のまま返す、という意味）が、🔴 **上流は `symbolize_keys` で
    # 揃えてからマスクする**ので、**型が残るかどうかは担保できないし、する必要も無い。**
    # ⚠ **見たかったのは「キー名で資格情報が落ちること」そのもの。**
    def test_string_keys_are_masked
      message = logger.create_message('token' => 'SECRET', 'post' => 'live')

      assert_not_include(message.to_json, 'SECRET')
      assert_equal('live', message[:post])
    end

    # ⚠ **`raise` していない例外**（バックトレースが無い）**でも Hash に潰れること。**
    #
    # 🔴 **1.15.28 では `error.backtrace.first` が `NoMethodError` になり、
    # `create_message` の rescue が渡された Hash を素で返していた** — ⚠⚠ **例外
    # オブジェクトが残るので `to_json` が `to_s` を呼び、同じ場所で落ちた。**
    # ⚠ **上流は `&.` で塞いだ**ので、**例外オブジェクトはここまで来ない。**
    #
    # ⚠⚠ **例外のクラス名は上流の形では残らない**（`message` / `file` / `line` のみ）。
    # ⚠ **`raise` した例外でも同じ**なので、この版で失われた情報ではない。
    def test_an_unraised_exception_is_flattened
      message = logger.create_message(error: Ginseng::GatewayError.new(broken))

      assert_nothing_raised {message.to_json}
      assert_include(message[:error][:message], 'wrong status line')
      assert_equal(0, message[:error][:line])
    end

    # ⚠ **妥当な UTF-8 は 1 バイトも変えない。**安全網が本文を壊さないこと。
    def test_valid_text_is_untouched
      message = logger.create_message(post: 'live', text: "剣崎真琴です。\nいくよ！")

      assert_equal("剣崎真琴です。\nいくよ！", message[:text])
    end

    # ⚠⚠ **資格情報のマスクを壊さない**（ginseng-core 側の `mask`）。
    #
    # ✅ **1.19.0 からは値の文字列に埋まったトークンも落ちる**（`mask_url` / 上流 `#493`）。
    # ⚠ **MAKOTO は Bearer ヘッダで投げ、cure-api の URL にも秘密が無い**ので、
    # **こちらが踏む形ではない**が、⚠⚠ **モロヘイヤ経由（#30）で経路が増えるときに効く。**
    def test_masking_still_works
      message = logger.create_message(post: 'live', token: 'SECRET', error: raised(broken))

      assert_not_include(message.keys, :token)
      assert_equal('live', message[:post])
    end

    # 🔴 **`create_message` が内部で例外を握っても秘密を出さないこと。**
    #
    # ⚠⚠ **1.15.28 は握ると渡された Hash を素で返していた** — **マスクが丸ごと外れ、
    # #79 の scrub が「ログが消える」を「秘密が漏れる」に変えていた**（2026-08-15 実測）。
    # ⚠ **こちらの `drop_secrets` はその保険だった。**
    #
    # ✅ **1.19.0 は fail closed**（上流 `#529`）— **通せなかったときは `_mask_error` と
    # キー名だけを出して中身を出さない。**🔴 **保険を外した根拠がこのテスト**なので、
    # ⚠⚠ **上流に返しても残す。**
    def test_secrets_are_dropped_even_when_the_superclass_mask_is_skipped
      [Ginseng::GatewayError.new('boom'), Ginseng::GatewayError.new(broken)].each do |error|
        message = logger.create_message(token: 'SECRET', post: 'live', error: error)

        assert_not_include(message.keys, :token)
        assert_not_include(message.to_json, 'SECRET')
      end
    end

    # ⚠ 入れ子の中の秘密も落とす。
    def test_nested_secrets_are_dropped
      payload = {
        context: {access_token: 'SECRET'},
        list: [{api_key: 'SECRET'}],
        error: Ginseng::GatewayError.new('boom'),
      }
      message = logger.create_message(payload)

      assert_not_include(message.to_json, 'SECRET')
    end

    # 🔴 **キーの大文字小文字を問わずマスクする**（#198 / v0.4.1）。
    #
    # ⚠⚠ **v0.4.0 の回帰だった** — **v0.3.0 までは `Makoto::Logger#secret?` が両側を
    # 小文字にして突き合わせていた**が、🔴 **#101 でその上書きごと上流へ返したところ、
    # 上流の `mask_field?` は完全一致で見ていた**（`config/application.yaml` の
    # `mask_fields` は全部小文字なので、⚠ **`Authorization` はヘッダの綴りそのままで
    # 素通りしていた**）。✅ **上流 `ginseng-core#584` を出して塞いだ。**
    #
    # ⚠ **`Authorization` を落とさない**（実際に踏むとしたらこれ）。
    def test_masking_ignores_the_case_of_the_key
      [:Token, :TOKEN, :Authorization].each do |key|
        message = logger.create_message(probe: 'mask', key => 'SECRET')

        assert_not_include(message.to_json, 'SECRET')
      end
    end

    # ⚠⚠ **設定が無くてもマスクしない方向へ倒さない。**設定の不備で秘密が平文に
    # 戻るほうが事故が大きい。
    #
    # ⚠ **倒し方が 2 度変わった:**
    #
    # | | 倒し先 |
    # | --- | --- |
    # | v0.3.0 まで | ⚠ **こちらの既定のキー名リスト**（`Makoto::Logger#secret?`） |
    # | v0.4.0（1.19.0） | ⚠ **上流が「マスクを通せなかった」として中身ごと出さない**（`_mask_error`） |
    # | 🔴 **v0.4.1（1.23.0）** | **上流の既定 `MASK_FIELDS`**（`password` / `secret` / `token` の 3 件） |
    #
    # 🔴 **3 つ目はこちらの `ginseng-core#584` が足した倒し先。**⚠ **`mask_field?` だけが
    # 「config が無ければ `ConfigError`」で、`mask_query_params` / `mask_url_paths` の
    # 「マスクしない方向へは倒さない」と揃っていなかった**ので合わせたもの。
    #
    # ⚠⚠ **ただし既定が 3 件しかないので、保護は 1 段狭くなった** — 🔴 **設定を落とすと
    # `access_token` / `authorization` / `api_key` は平文に戻る**（v0.4.0 は中身ごと
    # 出さなかった）。⚠ **上流 `ginseng-core#586` / PR `#607`（既定を広げ、設定とは
    # 合成する）で解ける** — **こちらに回避策は置かない**（→ docs/CLAUDE.md）。
    #
    # ⚠ **実運用では踏まない。**`config/application.yaml` が 7 件を自分で列挙しており、
    # **落ちるのは設定そのものが壊れたとき**（`rake config:lint` が見る側）。
    def test_masking_falls_back_to_the_defaults_without_the_setting
      config.delete('/logger/mask_fields')
      message = Logger.new.create_message(token: 'SECRET', error: Ginseng::GatewayError.new('boom'))

      assert_not_include(message.to_json, 'SECRET')
    end

    # 実際に syslog へ渡る手前の値。⚠ **`create_message` を直に呼ぶだけでは
    # 「その severity が出口を通っているか」を見られない**（#97 はまさにそこが穴だった）。
    def emitted(severity, payload)
      recorder = []
      subject = Logger.new
      subject.define_singleton_method(:add) do |_level, message = nil, progname = nil|
        recorder.push(message || progname)
        next true
      end
      subject.send(severity, payload)
      return recorder.first.to_s
    end

    # ⚠ 出す水準は設定から出す（#80 の黄 9）。
    def test_the_level_comes_from_the_setting
      config['/logger/level'] = 'debug'

      assert_equal(::Logger::Severity::DEBUG, Logger.new.level)
    end

    # ⚠⚠ **既定では `debug` を出さない。**⚠ **平常日に 171 行出ていた「本文が無い」を
    # 黙らせるのがこの水準の役目**（→ `PostingJob`）。
    def test_debug_is_silent_by_default
      assert_operator(Logger.new.level, :>, ::Logger::Severity::DEBUG)
      assert_operator(Logger.new.level, :<=, ::Logger::Severity::INFO)
    end

    # ⚠⚠ **読めない値でも落ちない。**⚠ **ログの出口が設定の不備で例外を上げると、
    # その例外を書く先も無い。**⚠ **黙る方向へは倒さない。**
    def test_a_broken_level_falls_back_to_info
      config['/logger/level'] = 'いつか'

      assert_equal(::Logger::Severity::INFO, Logger.new.level)
    end

    def test_the_level_falls_back_when_the_setting_is_gone
      config.delete('/logger/level')

      assert_equal(::Logger::Severity::INFO, Logger.new.level)
    end

    # 🔴 **#97 の本体。**⚠⚠ **1.15.28 が上書きしていたのは `info` と `error` の 2 つ
    # だけ**だったので、⚠ **`warn` は `Syslog::Logger` の実装がそのまま走り、マスクも
    # scrub も効いていなかった**（実測で `token` が平文で出た）。
    #
    # ⚠ **いまは上流（`#499`）が 5 つとも通す**ので、**こちらの上書きは #101 で外した。**
    # 🔴 **外したことが分かるのはこのテスト**なので、⚠⚠ **上流に返しても残す。**
    #
    # ⚠ **水準で黙らせない**（`debug` は既定で出ない ＝ 別のテストの担保）。
    def test_every_severity_goes_through_the_exit
      config['/logger/level'] = 'debug'
      [:info, :error, :warn, :debug, :fatal].each do |severity|
        output = emitted(severity, post: 'live', token: 'SECRET')

        assert_not_include(output, 'SECRET', severity.to_s)
        assert_include(output, '"post":"live"', severity.to_s)
      end
    end

    # ⚠⚠ **ブロック形式を殺さないこと**（上流 `#499`）。🔴 **こちらの上書きは
    # `ArgumentError` にしていた** — ⚠ **外した理由の 1 つがこれ。**
    #
    # ⚠ **水準が無効ならブロックを評価しない**（遅延の意味が失われる）。
    def test_the_block_form_survives
      config['/logger/level'] = 'info'
      called = false
      subject = Logger.new
      subject.define_singleton_method(:add) {|*| true}

      assert_nothing_raised {subject.warn {'lazy'}}
      assert_nothing_raised {subject.debug {called = true}}
      assert_false(called)
    end

    # ⚠ **不正なバイト列の scrub も severity で漏らさない**（#79 の経路が `warn` に
    # 残っていた）。
    def test_every_severity_survives_invalid_bytes
      [:info, :error, :warn, :debug, :fatal].each do |severity|
        assert_nothing_raised(severity.to_s) {emitted(severity, post: broken, error: raised(broken))}
      end
    end

    # ⚠⚠ **呼び出し側 6 箇所を直す案にしなかった理由の担保。**
    # ⚠ **出口 1 つで受けているので、`PostingJob` の経路もそのまま通る。**
    def test_the_posting_path_survives
      table = Timetable.new(start: '12:00', finish: '20:00', interval: '2m', timezone: 'Asia/Tokyo')
      job = PostingJob.new(name: 'live', timetable: table, source: proc {raise Ginseng::GatewayError, broken})

      assert_nothing_raised {job.exec(Time.new(2026, 11, 4, 12, 0, 0, '+09:00'))}
    end
  end
end
