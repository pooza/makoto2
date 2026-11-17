module Makoto
  class ChatArticleTest < TestCase
    HTML = <<~HTML.freeze
      <html><head><title>題（title）</title><meta property="og:title" content="感謝祭の開催が決まった">
      <script>alert('x')</script></head>
      <body><header>サイトの見出し</header><nav>メニュー</nav>
      <article><h1>感謝祭</h1><p>2027 年 2 月に開く。</p><p>  キャストが  そろう。 </p></article>
      <footer>著作権</footer></body></html>
    HTML

    # ⚠ テストの名前は引けないので、news.example だけは通す（他は既定の判定）。
    def article
      validator = ->(host) {host == 'news.example' || Ginseng::PublicHost.validator.call(host)}
      return ChatArticle.new(validator:)
    end

    def html_response(body = HTML, type = 'text/html; charset=utf-8')
      return {status: 200, body: body, headers: {'Content-Type' => type}}
    end

    # 🔴 **本文だけを平文で返す**（スクリプト・メニュー・フッタは落とす）。
    def test_extract_takes_the_article_paragraphs
      article = ChatArticle.extract(HTML)

      assert_equal('感謝祭の開催が決まった', article[:title])
      assert_equal("2027 年 2 月に開く。\nキャストが そろう。", article[:text])
    end

    def test_extract_cuts_long_text
      text = ChatArticle.extract("<p>#{'あ' * 5000}</p>")[:text]

      assert_equal(ChatArticle::ARTICLE_MAX_LENGTH + 1, text.length)
      assert(text.end_with?('…'))
    end

    def test_read_fetches_html
      stub_request(:get, 'https://news.example/a').to_return(html_response)

      assert_equal('感謝祭の開催が決まった', article.read('https://news.example/a')[:title])
    end

    # ⚠ HTML でなければ読まない。
    def test_read_rejects_non_html
      stub_request(:get, 'https://news.example/a.pdf').to_return(html_response('%PDF', 'application/pdf'))

      assert_raise(Ginseng::GatewayError) {article.read('https://news.example/a.pdf')}
    end

    # 🔴 **大きすぎる応答は読むのをやめる**（受け取りながら数える・PR #693 の Codex の P2）。
    def test_read_stops_at_the_byte_limit
      stub_request(:get, 'https://news.example/big').to_return(html_response('a' * (ChatArticle::MAX_BYTES + 1)))

      assert_raise(Ginseng::TooLargeError) {article.read('https://news.example/big')}
    end

    # 🔴 **内側のアドレスへは行かない**（リダイレクトの先も含めて）。
    def test_read_refuses_private_addresses
      stub_request(:get, 'https://news.example/r')
        .to_return(status: 302, headers: {'Location' => 'http://127.0.0.1/admin'})

      assert_raise(Ginseng::GatewayError) {article.read('http://127.0.0.1/admin')}
      assert_raise(Ginseng::GatewayError) {article.read('https://news.example/r')}
      assert_not_requested(:get, 'http://127.0.0.1/admin')
    end
  end
end
