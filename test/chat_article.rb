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

    # 🔴 **画像・写真のページは、元の記事へ戻してから読む**（#719・増子の配信に実際に出た 4 つの形）。
    def test_article_url_leaves_photo_pages
      {
        'https://news.yahoo.co.jp/articles/7d670ecdb020c4f261e431d3758913f68c526252/images/000' =>
          'https://news.yahoo.co.jp/articles/7d670ecdb020c4f261e431d3758913f68c526252',
        'https://mantan-web.jp/article/20261119dog00m200068000a/photopage/004.html' =>
          'https://mantan-web.jp/article/20261119dog00m200068000a.html',
        'https://s.animeanime.jp/article/img/2026/11/20/104940/952767.html' =>
          'https://s.animeanime.jp/article/2026/11/20/104940.html',
        'https://s.inside-games.jp/article/img/2026/11/05/190385/1803612.html' =>
          'https://s.inside-games.jp/article/2026/11/05/190385.html',
        'https://news.livedoor.com/article/image_detail/32843526/?img_id=57671144' =>
          'https://news.livedoor.com/article/detail/32843526/',
      }.each do |photo, article|
        assert_equal(article, ChatArticle.article_url(photo))
      end
    end

    # ⚠ 記事のページと、形の違うページはそのまま。
    def test_article_url_keeps_other_pages
      [
        'https://news.yahoo.co.jp/articles/7d670ecdb020c4f261e431d3758913f68c526252',
        'https://news.livedoor.com/article/detail/32859396/',
        'https://evil.example/articles/abc/images/000',
        'https://news.yahoo.co.jp.evil.example/articles/abc/images/000',
      ].each do |url|
        assert_equal(url, ChatArticle.article_url(url))
      end
    end

    def test_read_goes_to_the_article_of_a_photo_page
      photo = stub_request(:get, 'https://news.yahoo.co.jp/articles/abc/images/000')
      page = stub_request(:get, 'https://news.yahoo.co.jp/articles/abc').to_return(html_response)
      validator = ->(host) {host == 'news.yahoo.co.jp'}

      assert_equal('感謝祭の開催が決まった', ChatArticle.new(validator:).read('https://news.yahoo.co.jp/articles/abc/images/000')[:title])
      assert_requested(page)
      assert_not_requested(photo)
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
