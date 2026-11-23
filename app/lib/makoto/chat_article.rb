require 'nokogiri'

module Makoto
  # サンクルミエール通信の記事を読む（#654）。→ `ChatTools#read_news`
  #
  # ## 🔴 読みに行く先は、増子が配信した URL だけ
  #
  # URL はモデルから受け取らない。モデルが渡すのは見出しの一部で、URL は `ChatNews` が増子の投稿から取り出したもの。
  # ⚠⚠ 任意の URL を読ませると、外から内側を叩かせる穴になる（SSRF）。🔴 **リダイレクトの先も含めて、どのホップも
  # 公開のアドレスだけを通す**（`Ginseng::PublicHost.validator`）。⚠ 待ちは短く（→ `ChatLookup`）、読むのは HTML だけ、
  # 大きさにも上限を置く。
  #
  # ## 🔴 記事の中身はデータ
  #
  # 本文は `ARTICLE_MAX_LENGTH` 字までの平文にして返す。⚠ 指示めいた文があっても従わせない・文を返事に写さない、は
  # 道具の説明と指示書が言う（歌詞を引かないのと同じ考え方・#652）。
  class ChatArticle
    include Package
    include ChatLookup

    # 返す本文の上限（字）。⚠ 記事の要点は始めのほうにある。⚠ 1 本読むと入力が 約 1,400 トークン増える
    # （2026-11-18 の実測・`docs/CLAUDE.md`。上限まで取れた記事なら もう少し）。
    ARTICLE_MAX_LENGTH = 1500
    # 記事 1 本を読む全体の締め切り（秒）。🔴 **ginseng の `timeout` は socket の 1 回の待ちごと**で、リダイレクトも
    # 8 回まで追うので、少しずつ流してくる相手には返事のスレッドを長く掴まれうる（#701）。⚠ 実況の窓の締め切り
    # （`/chat/commentary/deadline` 30 秒）より十分短く。
    READ_DEADLINE = 10
    # 読む HTML の上限（バイト）。🔴 **受け取りながら数え、超えたら読むのをやめる**（`max_bytes`・PR #693 の Codex の P2）。
    # ⚠ 受け取ってから切ると、大きい応答や流し続ける相手でメモリが青天井になり、返事のスレッドも塞がる。
    MAX_BYTES = 1_000_000
    # 画像・写真のページから、元の記事へ戻す規則（#719）。🔴 **ホストは変えない**（戻した先も `PublicHost` を通る）。
    # ⚠ 増子の配信の約 8%（2026-11-23 に 400 本を見た）がこの 4 つの形で、本文の代わりにキャプションや
    # 別の記事（「あなたにオススメ」）が取れていた。⚠ 決め打ちのドメインは、配信に実際に出たものだけ。
    PHOTO_PAGES = [
      # Yahoo!ニュース: /articles/<id>/images/000
      [%r{\A(https://news\.yahoo\.co\.jp/articles/[0-9a-f]+)/images/\d+/?\z}, '\\1'],
      # MANTANWEB: /article/<id>/photopage/004.html
      [%r{\A(https://mantan-web\.jp/article/[0-9a-z]+)/photopage/\d+\.html\z}, '\\1.html'],
      # アニメ！アニメ！・インサイド（イード）: /article/img/YYYY/MM/DD/<id>/<画像>.html
      [
        %r{\A(https://(?:s\.)?(?:animeanime|inside-games)\.jp/article)/img/(\d{4}/\d{2}/\d{2}/\d+)/\d+\.html\z},
        '\\1/\\2.html',
      ],
      # ライブドアニュース: /article/image_detail/<id>/?img_id=…
      [
        %r{\A(https://news\.livedoor\.com/article)/image_detail/(\d+)/(?:\?\S*)?\z},
        '\\1/detail/\\2/',
      ],
    ].freeze
    # 本文として見ない要素。
    NOISE = 'script, style, noscript, nav, header, footer, aside, form, iframe, svg, button'.freeze

    # @param http [HTTP, nil] ⚠ テストが差し替える
    # @param validator [#call, nil] ⚠ テストが差し替える（既定は公開のアドレスだけを通す）
    def initialize(http: nil, validator: nil)
      @http = http
      @validator = validator
    end

    # @param url [String] ⚠ **増子が配信した URL だけを渡す**（→ クラスの冒頭）
    # @return [Hash] `{title:, text:}` ⚠ 読めなければ例外
    def read(url)
      validator = @validator || Ginseng::PublicHost.validator
      url = self.class.article_url(url)
      response = Timeout.timeout(READ_DEADLINE, Ginseng::GatewayError, 'news: article deadline') do
        http.get(url, {host_validator: validator, max_bytes: MAX_BYTES})
      end
      type = response.headers['content-type'].to_s
      raise Ginseng::GatewayError, "news: not html (#{type})" unless type.include?('html')
      return self.class.extract(response.body.to_s)
    end

    # 画像・写真のページなら元の記事の URL、そうでなければそのまま（→ `PHOTO_PAGES`）。
    def self.article_url(url)
      PHOTO_PAGES.each do |pattern, replacement|
        return url.sub(pattern, replacement) if url.match?(pattern)
      end
      return url
    end

    # HTML から題と本文を取り出す。
    def self.extract(html)
      doc = Nokogiri::HTML(html.scrub(''))
      title = doc.at('meta[property="og:title"]')&.[]('content') || doc.at('title')&.text
      doc.css(NOISE).each(&:remove)
      text = body_of(doc.at('article') || doc.at('main') || doc.at('body') || doc)
      text = "#{text[0, ARTICLE_MAX_LENGTH]}…" if text.length > ARTICLE_MAX_LENGTH
      return {title: squeeze(title.to_s), text:}
    end

    # 段落があれば段落を行にし、無ければ全体の文字。
    def self.body_of(root)
      text = root.css('p').map {|node| squeeze(node.text)}.reject(&:empty?).join("\n")
      return text.empty? ? squeeze(root.text) : text
    end

    def self.squeeze(text)
      return text.gsub(/[[:space:]]+/, ' ').strip
    end

    private

    def http
      return @http ||= quick(HTTP.new)
    end
  end
end
