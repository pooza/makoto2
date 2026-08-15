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
    # ⚠ **安全網はマスクの後に掛かる**ので、順番が入れ替わっていないことを見る。
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

    # ⚠⚠ **呼び出し側 6 箇所を直す案にしなかった理由の担保。**
    # ⚠ **出口 1 つで受けているので、`PostingJob` の経路もそのまま通る。**
    def test_the_posting_path_survives
      table = Timetable.new(start: '12:00', finish: '20:00', interval: '2m', timezone: 'Asia/Tokyo')
      job = PostingJob.new(name: 'live', timetable: table, source: proc {raise Ginseng::GatewayError, broken})

      assert_nothing_raised {job.exec(Time.new(2026, 11, 4, 12, 0, 0, '+09:00'))}
    end
  end
end
