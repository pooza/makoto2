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

    # 返す本文の上限（字）。⚠ 記事の要点は始めのほうにある。⚠ 1 回読むと入力が 2,000 トークンほど増える。
    ARTICLE_MAX_LENGTH = 1500
    # 読む HTML の上限（バイト）。⚠ これを超えたら先頭だけを見る。
    MAX_BYTES = 1_000_000
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
      response = http.get(url, {host_validator: @validator || Ginseng::PublicHost.validator})
      type = response.headers['content-type'].to_s
      raise Ginseng::GatewayError, "news: not html (#{type})" unless type.include?('html')
      return self.class.extract(response.body.to_s.byteslice(0, MAX_BYTES))
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
