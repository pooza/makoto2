require 'uri'

module Makoto
  # 原稿 1 本に使える本文の長さ（#282）。
  #
  # 🔴 **原稿を書く側から上限が見えなかった。**⚠ **いまの上限は `/mastodon/max_length` = 3000 字**
  # （キュアスタ！の設定。→ docs/CLAUDE.md「3000 字」）— ⚠⚠ **`PostBudget#limit` は設定から読むので、
  # ここに数字を書かない**（🔴 **このコメントは #282 の時点の「500 字」で 1 リリース古くなっていた** ＝ #353）。⚠⚠ **超えると投稿先が 422 を返し、
  # 再送なしの失敗としてその枠が消える**（`MastodonService::PERMANENT_STATUSES`）— ⚠ **気づくのは
  # 投稿の瞬間**で、**通年 366 本の朝挨拶を書き足していく箱**では、壁に当たるのは原稿が増えたとき。
  # 🔴 **だから取り込み（`ScriptImporter`）で弾く。**
  #
  # ## ⚠ 引くのは「前後に付く定型文」
  #
  # | type | 投稿の形 | 予約 |
  # | --- | --- | --- |
  # | **朝挨拶**（`/morning/type`） | 定型挨拶 ＋ 改行 ＋ 本文 | 挨拶の長さ ＋ 1 |
  # | **曲紹介の前置き** | 本文 ＋ 空行 ＋ 曲の行 | `TRACK_RESERVE` |
  # | **ライブの台本** | 本文 ＋ 改行 ＋ ハッシュタグ | タグの長さ ＋ 1 |
  # | それ以外 | 本文だけ | 0 |
  #
  # 🔴 **モロヘイヤを経由するときは、さらに `/mastodon/proxy_reserve` を全部の type から引く**
  # （転送時にタグの行を足すため）。
  #
  # ⚠ **URL は投稿先と同じく 23 字と数える**（`holiday` は素の長さ 576 字だが実効 328 字）。
  class PostBudget
    include Package

    # 🔴 **Mastodon は URL の長さによらず 23 字と数える。**
    URL_LENGTH = 23

    # ⚠ **投稿先が URL と認めるスキーム**（Mastodon の `valid_url` の上書き）。🔴 **`gemini://` なども
    # 23 字と数える**ので、**素の長さで数えると短い URL を短く見積もる**（#443）。
    SCHEMES = ['http', 'https', 'dat', 'dweb', 'ipfs', 'ipns', 'ssb', 'gopher', 'gemini'].freeze

    # ⚠ **`URI.extract` と同じ規則**。🔴 **直前に英数字・`@`・`$`・`#` があれば URL ではない**
    # （twitter-text の `valid_url_preceding_chars`・#443）— ⚠⚠ **`xhttps://…` を投稿先は素の長さで数える。**
    URL_PATTERN = Regexp.new(
      "(?<![A-Za-z0-9@＠$#＃\uFFFE\uFEFF\uFFFF])#{URI::RFC2396_PARSER.make_regexp(SCHEMES).source}",
      Regexp::EXTENDED,
    )

    # 🔴 **Public Suffix List にあって twitter-text 3.1.0 の TLD 表に無いもの**（#443）。⚠⚠ **投稿先は
    # URL と認めず素の長さで数える**（⚠ **`.music` は音楽 bot として現実的**）。
    # ⚠ **表は gem の `tld_lib.yml` と PSL の差分を取った実測**（2026-09-26）。
    UNKNOWN_TLDS = ['amazon', 'hotel', 'kids', 'merck', 'music', 'spa'].freeze

    # ⚠ **これより長い URL を投稿先は URL と認めない**（twitter-text の `MAX_URL_LENGTH`）。
    MAX_URL_LENGTH = 4096

    # ⚠ **t.co は英数字の slug までしか URL にしない**（twitter-text の `valid_tco_url`）。
    TCO_PATTERN = %r{\Ahttps?://t\.co/([a-z0-9]+)}i
    MAX_TCO_SLUG_LENGTH = 40

    # ⚠⚠ **曲の行（曲名・名義・アルバム名・URL）に取っておく長さ。**🔴 **実測の最大は 277 字**
    # （2026-09-08・`bgm`・名義 102 字 → #282）＋ 空行 2 字に余裕を持たせた。
    # ⚠ **曲は抽選なので、前置きの側でどの曲に付くかは決められない** ＝ 最悪に合わせる。
    TRACK_RESERVE = 300

    # 投稿先が数える長さ。
    #
    # ⚠⚠ **書記素クラスタで数える**（Codex の P2）。🔴 **Mastodon は URL を置き換えたあと、見た目の
    # 1 文字（結合文字・ZWJ の絵文字）を 1 字と数える** — ⚠ **`String#length` はコードポイント
    # なので、家族の絵文字 1 つが数字ぶん長く出て、上限の近くで通る原稿を弾いてしまう。**
    #
    # ⚠⚠ **URL は 1 回の走査で置き換える**（Codex の P2）。🔴 **1 本ずつ `gsub` すると、前方一致
    # する URL（`/a` と `/a/b`）で短いほうが長いほうの中まで置き換え、長く数えてしまう。**
    #
    # ⚠ **実在する TLD を持たないホスト（素の IP・`localhost`・`foo.local`）は URL と数えない**（#351）。
    # 🔴 **投稿先（twitter-text）は IANA の TLD でしか URL と認めず、素の長さで数える**ので、
    # **23 字に畳むと短く見積もる**（⚠⚠ **弾きすぎる向きのずれは許すが、通しすぎる向きは許さない**）。
    # ⚠ **TLD の表は Public Suffix List**（`default_rule: nil` ＝ 表に無ければ URL でない・Codex の P2）。
    #
    # 🔴 **URL の末尾の句読点は URL の外で数える**（#424）。⚠⚠ **`URL_PATTERN` は `a.` の `.` まで
    # 飲み込むが、投稿先はそれを URL から外して 1 字と数える** ＝ **URL 1 本につき 1 字通しすぎる**
    # （→ `split_trailing`）。
    #
    # 🔴 **URL と言い切れないときは長いほうで数える**（#443）。⚠⚠ **TLD は投稿先も知っているのに
    # ホストとしては認めない形**（`co.uk` のような接尾辞そのもの）は、**投稿先が URL と数えるかを
    # こちらで決めきれない** — 🔴 **素の長さと 23 字の大きいほうを取る**（弾きすぎる向きに倒す）。
    def self.length(text)
      counted = text.to_s.gsub(URL_PATTERN) do |url|
        core, trailing = split_trailing(url, Regexp.last_match.post_match[0])
        folded = ('x' * URL_LENGTH) + trailing
        case url_kind(core)
        when :url then folded
        when :maybe then [folded, url].max_by(&:length)
        else url
        end
      end
      return counted.grapheme_clusters.size
    end

    # ⚠ **クエリの末尾に来てよい文字**（Mastodon の `valid_url_query_ending_chars` の ASCII ぶん）。
    QUERY_ENDING = %r{[a-z0-9_&=#/-]}i

    # ⚠ **path の末尾に来てはいけない文字**（Mastodon の `valid_url_path_ending_chars` の否定）。
    # ⚠⚠ **閉じ括弧は含めない** — 🔴 **`cut_at_parens` を通った後に残る `)` は認められた 1 組の閉じ**
    # （`Foo_(bar)` は URL）。
    PATH_NOT_ENDING = /[(?!*"'<>;:=,.$%\[\]~&|]/

    # URL を「投稿先が URL と数える部分」と「その後ろの文字」に割る（#424 / #443）。
    #
    # 🔴 **正本は Mastodon の `config/initializers/twitter_regex.rb`**（twitter-text の規則を
    # 上書きしている）。⚠⚠ **クエリと path で末尾の規則が違う** — **`?b=` / `?b=1&` はクエリなら
    # URL の一部、path なら外**。
    #
    # 🔴 **末尾だけでなく途中でも終わる**（#443）— ⚠⚠ **`URL_PATTERN`（RFC2396）は投稿先より広く飲み込む**:
    #
    # - ホスト（と port）の後ろは `/` か `?` でなければ URL はそこで終わる（`#frag`・`%20`・userinfo の `@`）
    # - path の括弧は中身のある 1 組（入れ子 1 段まで）だけ（→ `cut_at_parens`）
    # - path の末尾を削ったら、その後ろのクエリも URL ではない（クエリは path の直後にしか付かない）
    #
    # ⚠ **`following` は照合の直後の 1 字**（`URL_PATTERN` はホストの `+` の手前で止まる → `cut_at_tld`）。
    def self.split_trailing(url, following = nil)
      core = cut_at_parens(cut_at_authority(cut_at_tld(url, following)))
      if (tco = core.match(TCO_PATTERN))
        return core, url[core.length..] if tco[1].length > MAX_TCO_SLUG_LENGTH
        core = tco[0]
      end
      path, query = core.split('?', 2)
      core = trim_path(path)
      if core == path && query
        query = trim_query(query)
        core = "#{path}?#{query}" unless query.empty?
      end
      return core, url[core.length..]
    end

    # ⚠ **ホストに来てよい文字と port**（twitter-text の `valid_domain` の ASCII ぶん・`valid_port_number`）。
    # ⚠⚠ **`_` は入れない**（サブドメインには来てよいが、TLD の直後で切れる）— **切って短く見るのは
    # 長く数える向き**なので、ここでは区別しない。
    AUTHORITY = %r{\A([^:]+)://([a-z0-9.-]*)(?::[0-9]+)?}i

    # ⚠ **TLD の直後に来てはいけない文字**（twitter-text の `valid_tld` の先読み）。
    TLD_NOT_FOLLOWED_BY = ['@', '+'].freeze

    # ホストの最後が知らない TLD なら、手前の知っている TLD まで戻って切る（#443）。
    #
    # 🔴 **投稿先はホストの正規表現を後戻りさせる**ので、**`example.com.aaa` は `example.com` までを
    # URL と数える**（実測）。⚠⚠ **全体を URL でないとして素の長さで数えると、短く見積もる。**
    def self.cut_at_tld(url, following = nil)
      matched = url.match(AUTHORITY)
      return url unless matched
      labels = matched[2].split('.', -1)
      following = url[matched.begin(2) + matched[2].length] || following
      last = labels.size - 1
      last.downto(1) do |index|
        next unless known_tld?(labels[index])
        next if index == last && TLD_NOT_FOLLOWED_BY.include?(following)
        return index == last ? url : "#{matched[1]}://#{labels[0..index].join('.')}"
      end
      return url
    end

    def self.known_tld?(label)
      tld = label.to_s.downcase
      return false if tld.empty? || UNKNOWN_TLDS.include?(tld)
      return PublicSuffix.valid?("x.#{tld}", default_rule: nil)
    end

    # ホスト（と port）の直後が `/` か `?` でなければ、そこで切る（#443）。
    #
    # ⚠ **直後が `@` なら切らない**（userinfo の形）— 🔴 **投稿先はホストだけを URL にせず、全体を
    # 素の長さで数える**（実測）。**切らずに渡せば `url_kind` が userinfo として弾く。**
    def self.cut_at_authority(url)
      authority = url[AUTHORITY]
      return url if authority.nil? || ['/', '?', '@'].include?(url[authority.length])
      return authority
    end

    def self.trim_path(path)
      path = path[0...-1] while path.length.positive? && path[-1].match?(PATH_NOT_ENDING)
      return path
    end

    def self.trim_query(query)
      query = query[0...-1] while query.length.positive? && !query[-1].match?(QUERY_ENDING)
      return query
    end

    # ⚠ **path に来てよい文字**（Mastodon の `valid_general_url_path_chars`）。
    PATH_CHARS = '[^\\s<>()?]'.freeze

    # ⚠ **path に認められる括弧の 1 組**（Mastodon の `valid_url_balanced_parens`）。
    BALANCED_PARENS = /\G\((?:#{PATH_CHARS}+|#{PATH_CHARS}*\(#{PATH_CHARS}+\)#{PATH_CHARS}*)\)/

    # path の途中で、投稿先が認めない括弧の手前まで切る（#443）。⚠ **クエリの括弧は URL の一部**なので見ない。
    def self.cut_at_parens(url)
      start = url.index('/', url.index('://').to_i + 3)
      return url unless start
      finish = url.index('?', start) || url.length
      index = start
      while index < finish
        case url[index]
        when '('
          matched = url.match(BALANCED_PARENS, index)
          return url[0...index] unless matched && matched.end(0) <= finish
          index = matched.end(0)
        when ')' then return url[0...index]
        else index += 1
        end
      end
      return url
    end

    # 投稿先がその URL を 23 字と数えるか（#351 / #443）。
    #
    # - `:url` — 数える
    # - `:maybe` — TLD は知っているが、ホストとしては認めない（→ `length` は長いほうで数える）
    # - `:none` — 数えない（素の長さ）
    #
    # ⚠⚠ **`:none` は「投稿先も URL と認めない」と言い切れる形だけ**（素の IP・TLD の無いホスト・
    # userinfo・`-` で始まるか終わるラベル・長すぎる URL・twitter-text の表に無い TLD）。
    def self.url_kind(value)
      return :none if value.length > MAX_URL_LENGTH
      uri = URI.parse(value)
      host = uri.host.to_s
      return :none if uri.userinfo || host.empty?
      labels = host.split('.')
      return :none if labels.any? {|label| label.start_with?('-') || label.end_with?('-')}
      return :none unless known_tld?(labels.last)
      return PublicSuffix.valid?(host, default_rule: nil) ? :url : :maybe
    rescue URI::InvalidURIError
      return :none
    end

    # 投稿先の申告と設定を突き合わせる（#351）。
    #
    # 🔴 **危ないのは申告のほうが短いときだけ**（取り込みは設定の上限で通すので、投稿の瞬間に
    # 422 ＝ 再送なしで枠が消える）。⚠ **長いぶんには弾きすぎるだけ。**⚠ **申告が無ければ判定しない。**
    #
    # @return [String, nil] ずれていれば、その説明
    def limit_mismatch(declared)
      return nil if declared.nil? || limit <= declared
      return "/mastodon/max_length は #{limit} 字だが、投稿先の申告は #{declared} 字"
    end

    def limit
      return config['/mastodon/max_length'].to_i
    end

    # その type の原稿が使える長さ。
    #
    # ⚠⚠ **日付つきの朝挨拶には定型挨拶が付かない**（Codex の P2 → `MorningSource#greeting_for`
    # — **挨拶は原稿が自分で持つ**）。🔴 **type だけで挨拶の分を引くと、日付つきの原稿を 25 字
    # ぶん不当に弾く。**
    def budget(type, dated: false)
      return limit - proxy_reserve - reserve(type.to_s, dated: dated)
    end

    # 🔴 **モロヘイヤが転送時に足すタグのぶん**（Codex の P2）。⚠⚠ **経由しないなら 0。**
    def proxy_reserve
      return 0 unless config['/mastodon/mulukhiya']
      return optional_config('/mastodon/proxy_reserve', 0).to_i
    end

    # ⚠ **超えていれば `ValidateError`**（どれだけ超えたかを言う）。
    #
    # ⚠ **空の本文も弾く**（#352）。🔴 **取り込みは手前で見ているが、`makoto message add` は
    # ここしか通らない。**
    def validate(type, body, slug, dated: false)
      raise Ginseng::ValidateError, "#{slug}: 本文がありません" if body.to_s.strip.empty?
      length = self.class.length(body)
      allowed = budget(type, dated: dated)
      return if length <= allowed
      raise Ginseng::ValidateError,
        "#{slug}: 本文が長すぎます（#{length} 字 / この type は #{allowed} 字まで・URL は #{URL_LENGTH} 字と数える）"
    end

    private

    def reserve(type, dated: false)
      value = reserves.fetch(type, 0)
      value = [value - greeting_reserve, 0].max if dated && type == Morning.new.type
      return value
    end

    # ⚠ **type は設定から引く**（書き写さない）。⚠⚠ **同じ type が複数の形に出たら大きいほう。**
    def reserves
      unless @reserves
        @reserves = {}
        add_reserve(Song.new.prefix_types, TRACK_RESERVE)
        add_reserve(Live.new.types, tag_reserve)
        add_reserve(Morning.new.type, greeting_reserve)
      end
      return @reserves
    end

    def add_reserve(types, value)
      Array(types).each {|type| @reserves[type.to_s] = [@reserves[type.to_s].to_i, value].max}
    end

    # ⚠⚠ **ハッシュタグは任意の設定**（`Live#hashtag` は `optional_config`）— 🔴 **素の `config[]`
    # で読むと、タグを外した設定ですべての取り込み（朝挨拶も）が落ちる**（Codex の P2）。
    #
    # ⚠⚠ **正規化した形で数える**（Codex の P2）。🔴 **`#` を書かない設定も `HashtagSource` は
    # 受け、`TagContainer` が `#` を足す**ので、素の設定値では 1 字短く出る。
    def tag_reserve
      hashtag = Live.new.hashtag
      return 0 if hashtag.empty?
      container = Ginseng::Fediverse::TagContainer.new
      container.push(hashtag)
      tags = container.to_s
      return 0 if tags.empty?
      return tags.grapheme_clusters.size + 1
    end

    def greeting_reserve
      greeting = Morning.new.greeting
      return 0 if greeting.empty?
      return greeting.grapheme_clusters.size + 1
    end
  end
end
