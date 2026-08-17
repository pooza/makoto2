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
    def test_nested_values_are_scrubbed
      message = logger.create_message(track: {name: broken, artists: [broken]})

      assert_true(message[:track][:name].valid_encoding?)
      assert_true(message[:track][:artists].first.valid_encoding?)
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

    # ⚠ **キーの型を変えない。**⚠⚠ `String` にすると ginseng 側の `mask_fields`
    # （キー名で資格情報を落とす）の見え方が変わる。
    def test_key_types_are_preserved
      message = logger.create_message(post: 'live', 'text' => broken)

      assert_include(message.keys, :post)
      assert_include(message.keys, 'text')
    end

    # ⚠ **例外オブジェクトが素で残る場合がある** — `create_message` は内部で例外を
    # 握ると**渡された Hash をそのまま返す**（バックトレースの無い例外など）。
    # ⚠⚠ **その `to_json` は `to_s` を呼ぶので、ここで潰さないと同じ場所で落ちる。**
    def test_an_unraised_exception_is_flattened
      message = logger.create_message(error: Ginseng::GatewayError.new(broken))

      assert_nothing_raised {message.to_json}
      assert_include(message[:error].to_s, 'Ginseng::GatewayError')
    end

    # ⚠ **妥当な UTF-8 は 1 バイトも変えない。**安全網が本文を壊さないこと。
    def test_valid_text_is_untouched
      message = logger.create_message(post: 'live', text: "剣崎真琴です。\nいくよ！")

      assert_equal("剣崎真琴です。\nいくよ！", message[:text])
    end

    # ⚠⚠ **資格情報のマスクを壊さない**（ginseng-core 側の `mask`）。
    #
    # ⚠ **いま入っている ginseng-core（1.15.28）が落とせるのはキー名だけ**で、
    # ⚠⚠ **値の文字列に埋まったトークン（`url: "...?access_token=xxx"`）は素通りする**
    # （上流の新しい版には `mask_url` がある）。**MAKOTO は Bearer ヘッダで投げ、
    # cure-api の URL にも秘密が無い**ので、いまは踏まない。
    def test_masking_still_works
      message = logger.create_message(post: 'live', token: 'SECRET', error: raised(broken))

      assert_not_include(message.keys, :token)
      assert_equal('live', message[:post])
    end

    # 🔴 **`Ginseng::Logger#create_message` は内部で例外を握ると、渡された Hash を
    # マスクを通さずにそのまま返す。**⚠ **実際に踏むのは `backtrace` を持たない例外**
    # （`raise` していない例外を `error:` に渡した形）。
    #
    # ⚠⚠ **#79 の scrub はこれを悪化させた** — **修正前は syslog で落ちて「ログごと
    # 消えて」いたものが、出力できるようになった結果、秘密がそのまま書かれる。**
    # **「ログが消える」を「秘密が漏れる」に変えていた。**
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

    # ⚠⚠ **設定が無くてもマスクしない方向へ倒さない。**設定の不備で秘密が平文に
    # 戻るほうが事故が大きい（→ `Logger::MASK_FIELDS`）。
    def test_masking_falls_back_to_the_default_list
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

    # 🔴 **#97 の本体。**⚠⚠ **上流が上書きしているのは `info` と `error` の 2 つだけ**
    # だったので、⚠ **`warn` は `Syslog::Logger` の実装がそのまま走り、`drop_secrets` も
    # `scrub` も効いていなかった**（実測で `token` が平文で出た）。
    def test_every_severity_goes_through_the_exit
      [:info, :error, :warn, :debug, :fatal].each do |severity|
        output = emitted(severity, post: 'live', token: 'SECRET')

        assert_not_include(output, 'SECRET', severity.to_s)
        assert_include(output, '"post":"live"', severity.to_s)
      end
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
