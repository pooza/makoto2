require 'securerandom'

module Makoto
  # Mastodon への投稿口。ginseng-fediverse の実装に、MAKOTO 用のエラー分類を被せたもの。
  #
  # ⚠ **MAKOTO は無人で投稿し続ける。**呼び出し側が「もう一度投げてよいのか」を
  # 判断できないと、失敗のたびに無駄な再送を繰り返すか、逆に諦めなくてよい失敗で
  # 沈黙する。そのため恒久的な失敗（認証・スコープ・入力不正）と一時的な失敗
  # （5xx・レート制限・タイムアウト）を必ず分けて上げる。
  #
  # 再送そのものは ginseng-core 1.15.28 以降の `HTTP#retryable?` が持つ
  # （恒久的な失敗は再送しない。回数は `/http/retry/limit`）。
  #
  # ⚠ **その再送は「投稿が二重に出る」経路でもある。**Mastodon が受理した後に
  # 応答だけが失われると（タイムアウト・逆プロキシの 502/503）、再送は同じ内容の
  # 投稿をもう 1 つ作る。`Idempotency-Key` を 1 回の `post_status` につき 1 つ作り、
  # 全試行で使い回してサーバー側に畳ませる。
  #
  # 🔴 **⚠⚠ モロヘイヤを経由するかは `X-Mulukhiya` の有無で決まる**（#124）。
  # ⚠ **ヘッダを付けたほうが「経由しない」** — モロヘイヤ側の nginx が
  # `map $http_x_mulukhiya $mulukhiya_backend` で**付いている要求を Mastodon 本体へ
  # 直に流す**（自己ループ防止）。⚠⚠ **ginseng-fediverse の既定は「付ける」なので、
  # 素で継承すると黙って迂回する** — **2026-08-19 の当日通しリハーサル 162 投稿が
  # 1 本もモロヘイヤを通っていなかった。**
  #
  # ⚠ **迂回するとタグ付け・URL 正規化・画像添付が掛からない。**⚠⚠ **旧アカウントの
  # 朝挨拶に 10 年付いていた `#precure_fun` はモロヘイヤが付けたもの**で、
  # **キュアスタ！のタグ＝コミュニティ側の導線**（→ docs/CLAUDE.md「北極星」）。
  class MastodonService < Ginseng::Fediverse::MastodonService
    include Package

    # 再送しても結果が変わらない状態。
    PERMANENT_STATUSES = {
      400 => Ginseng::RequestError,
      401 => Ginseng::AuthError,
      403 => Ginseng::AuthError,
      404 => Ginseng::NotFoundError,
      422 => Ginseng::ValidateError,
    }.freeze

    # メンションを受ける SSE の口（#29）。⚠ **通知だけを流すストリーム**（ホームの投稿は来ない）。
    STREAMING_PATH = '/api/v1/streaming/user/notification'.freeze

    # フォロワーの一覧を辿るページ数の上限（80 件ずつ ＝ 8,000 人）。⚠ 尽きたら例外（途中までを返さない）。
    FOLLOWER_MAX_PAGES = 100

    # ginseng-upstream: no — モロヘイヤを経由して投稿するか（`/mastodon/mulukhiya`）はこのアプリの経路の設定
    def initialize(uri = nil, token = nil)
      super
      # ⚠ **`optional_config` で既定値に逃がさない**（→ Package#optional_config）。
      # ⚠⚠ **設定を消しただけで経路が静かに戻る形を作らない**（#77 の裏返し）。
      # schema の required に入れてあるので、消せば `rake config:lint` が落ちる。
      self.mulukhiya_enable = config['/mastodon/mulukhiya']
    end

    # 自分自身の acct。ステージングは @test、本番は @makoto と異なるため、
    # コード側に定数として持たせない。
    def acct
      return config['/mastodon/acct']
    end

    # 疎通確認用。投稿せずにトークンの有効性とスコープを確かめられる。
    #
    # ⚠⚠ **ここは経路の設定に関わらず常に直で叩く**（#124）。⚠ **トークンの検査に
    # モロヘイヤの都合を巻き込まない** — nginx の `map` が掛かるのは投稿の側で、
    # ⚠⚠ **#106 で失効を見に行くときに「モロヘイヤが落ちている」が「トークンが
    # 死んでいる」に化けると、当日いちばん困る形**になる。
    #
    # 🔴 **リダイレクト先のホストを検証する**（#349）。⚠⚠ **HTTParty が既定でリダイレクトを
    # 追うのに、`options[:headers]` に直接置いた `Authorization` はホストが変わっても
    # 剥がされない**（守られるのは `basic_auth` / `digest_auth` だけ）。⚠ **`/mastodon/url` の
    # vhost が 301 / 302 を返す構成になった日**（nginx の `return 301`・ドメインの移転・
    # 証明書切替時の暫定）に、🔴 **常駐の起動ごと（`MakotoDaemon#verify_credentials`）と
    # `makoto whoami` のたびに、フルスコープのボットトークンが転送先ホストへ送られる。**
    #
    # ⚠ **`follow_redirects: false` で一律に切らず、`host_validator` を渡す**
    # （🔴 **ginseng-core が用意した口** — **ホップごとにホストを検証**し、
    # ⚠⚠ **オリジンが変わる先へは資格情報のヘッダとオプションを渡さない**）。
    # ⚠ **同一ホストの 301（`http` → `https` など）は追えるまま**で、**別ホストは
    # `GatewayError "Rejected host '...'"` で落ちる** — ⚠⚠ **3xx が黙って `nil` の
    # 本文になるのではなく、読めるエラーになる。**
    #
    # 🔴 **上流 [`ginseng-fediverse#280`](https://github.com/pooza/ginseng-fediverse/issues/280)
    # が入っても、ここは畳まない** — ⚠⚠ **上流の `MastodonService` は
    # `verify_credentials` を持たず、この呼び出し口は makoto2 のもの**（#282 で
    # 塞いだ投稿の口とは分界が違う）。
    #
    # 🔴 **`follow_redirects: true` は明示しておく**（#486）。⚠⚠ **fediverse のガード
    # （`RedirectGuard`）は資格情報を見ると `follow_redirects: false` を足す**が、
    # **`ginseng-core` 1.25.1 の `host_validator` の経路はこのキーを無視していた**ので
    # 同一ホストの 301 を追えていた。🔴 **2.0.0 はこのキーを尊重する**ので、書かないと
    # 同一ホストの 301 まで `GatewayError` になる。⚠ **ガードは `options.key?(:follow_redirects)`
    # なら手を付けない（明示が勝つ）**うえ、⚠ **別ホストへは `host_validator` が
    # 資格情報を渡さない**ので、上の意図（同一ホストは追う・別ホストは読めるエラー）は変わらない。
    def account
      response = http.get('/api/v1/accounts/verify_credentials', {
        headers: direct_headers,
        host_validator: ->(host) {host == http.base_uri.host},
        follow_redirects: true,
      })
      return response.parsed_response
    rescue Ginseng::GatewayError => e
      raise classify(e)
    end

    # acct からアカウントを引く（#20 の `makoto chat block`）。⚠ **見つからなければ nil。**
    # ⚠ 経路の設定に関わらず直で聞く（→ `#account`）。
    def lookup_account(acct)
      query = URI.encode_www_form(acct: acct.to_s.delete_prefix('@'))
      response = http.get("/api/v1/accounts/lookup?#{query}", {
        headers: direct_headers,
        host_validator: ->(host) {host == http.base_uri.host},
        follow_redirects: true,
      })
      body = response.parsed_response
      return body.is_a?(Hash) && body['id'] ? body : nil
    rescue Ginseng::GatewayError => e
      return nil if e.source_status == 404
      raise classify(e)
    end

    # 投稿先が申告する本文の上限（#351）。⚠ **無ければ nil。**
    #
    # 🔴 **上流の `max_post_text_length` を使わない** — ⚠⚠ **取れないと設定の既定値（500）に
    # 倒れる**ので、**「申告が 500」と「聞けなかった」の区別が付かない。**⚠ **聞けなければ例外。**
    #
    # ⚠ **トークンは付けない**（公開の口）。⚠ **経路の設定に関わらず直で聞く**（→ `#account`）。
    def declared_max_length
      response = http.get('/api/v1/instance', {headers: {'X-Mulukhiya' => package_class.full_name}})
      body = response.parsed_response
      return nil unless body.is_a?(Hash)
      return body.dig('configuration', 'statuses', 'max_characters')&.to_i
    rescue Ginseng::GatewayError => e
      raise classify(e)
    end

    # MAKOTO のフォロワーの ID を全部（#510 の門 → `FollowerRoster`）。⚠ **投稿しない**ので副作用は無い。
    #
    # 🔴 **`/api/v1/accounts/relationships` を使わない** — ⚠⚠ **`read:follows` が要り、いまのトークン
    # （`read:accounts read:notifications write:statuses write:media`）では 403**（2026-11-07 に実測）。
    # **スコープは発行後に足せない**ので、`read:accounts` で引ける自分のフォロワー一覧を使う。
    #
    # ⚠ **ページは `Link` の `next` を辿る**（80 件ずつ）。⚠ **辿る先は同じホストのときだけ**、
    # 経路の設定に関わらず直で聞く（→ `#account`）。🔴 **聞けなければ例外**（途中までの一覧を返さない —
    # ⚠⚠ 欠けた一覧で「フォロワーでない」と答えると、フォロワーへ「フォローしてくれたら」を返してしまう）。
    def follower_ids(max_pages: FOLLOWER_MAX_PAGES)
      return account_ids('followers', max_pages:)
    end

    # MAKOTO がフォローしている相手の ID を全部（#606）。⚠ 引き方と失敗の扱いは `#follower_ids` と同じ。
    # ⚠ **`read:follows` が要る**（2026-11-08 に作り直したトークンにはある）。⚠ 承認待ちのフォローは入らない。
    def following_ids(max_pages: FOLLOWER_MAX_PAGES)
      return account_ids('following', max_pages:)
    end

    # フォローする（#606）。⚠ **`write:follows` が要る。**⚠ 鍵の掛かった相手は承認待ちになる（応答の `requested`）。
    # @return [Hash] relationship
    def follow(account_id)
      return relationship_action(account_id, 'follow')
    end

    # フォローを外す（#606）。
    # @return [Hash] relationship
    def unfollow(account_id)
      return relationship_action(account_id, 'unfollow')
    end

    # 返信の祖先（前のやりとり・#18）。⚠ **古い順。**⚠ **投稿しない**ので副作用は無い。
    #
    # 🔴 **`read:statuses` が要る**（2026-11-08 にトークンを作り直した）。⚠ トークンが無くても公開・未収載の
    # 投稿は引けるが、フォロワー限定と DM の会話が見えない。⚠ 経路の設定に関わらず直で聞く（→ `#account`）。
    # `since_id` より新しいメンションの通知を、古い順に（#610 → `MentionCatchUp`）。
    # ⚠ `read:notifications` が要る。
    # ⚠ **`since_id` は新しい側から `limit` 件**（`min_id` は古い側から）。上限を超えたら
    # 古い側を落とす（古いほうは 15 分を超えて捨てる側なので）。
    # @return [Array<Hash>]
    def mentions_since(since_id, limit: 40)
      query = URI.encode_www_form('types[]' => 'mention', 'since_id' => since_id.to_s, 'limit' => limit)
      response = http.get("/api/v1/notifications?#{query}", {
        headers: direct_headers,
        host_validator: ->(host) {host == http.base_uri.host},
        follow_redirects: true,
      })
      body = response.parsed_response
      raise_unexpected(body.class.name) unless body.is_a?(Array)
      mentions = body.select {|entry| entry.is_a?(Hash) && entry['type'] == 'mention'}
      return mentions.sort_by {|entry| entry['id'].to_i}
    rescue Ginseng::GatewayError => e
      raise classify(e)
    end

    def status_ancestors(id)
      path = "/api/v1/statuses/#{URI.encode_www_form_component(id.to_s)}/context"
      response = http.get(path, {
        headers: direct_headers,
        host_validator: ->(host) {host == http.base_uri.host},
        follow_redirects: true,
      })
      body = response.parsed_response
      raise_unexpected(body.class.name) unless body.is_a?(Hash) && body['ancestors'].is_a?(Array)
      return body['ancestors']
    rescue Ginseng::GatewayError => e
      raise classify(e)
    end

    # メンションを受ける SSE の口（#29）。⚠ **トークンは載せない**（→ `streaming_headers`）。
    #
    # 🔴 **ホストは投稿先が申告する `urls.streaming_api` から引く** — ⚠ **Streaming API は
    # 本体と別のホストに置ける**ので、`/mastodon/url` から組み立てない。⚠ 申告は `wss://` なので
    # SSE 用に `https://` へ読み替える。⚠ **申告が無ければ本体のホストに倒す。**
    #
    # ⚠ **上流の `create_streaming_uri` を使わない** — ⚠⚠ **トークンをクエリに載せる**ので、
    # 逆プロキシのアクセスログに残る。
    # ginseng-upstream: pooza/ginseng-fediverse#334
    def streaming_uri
      response = http.get('/api/v1/instance', {headers: {'X-Mulukhiya' => package_class.full_name}})
      body = response.parsed_response
      declared = body.dig('urls', 'streaming_api') if body.is_a?(Hash)
      uri = URI.parse(declared.presence || http.base_uri.to_s)
      uri = URI.parse(uri.to_s.sub(/\Awss:/, 'https:').sub(/\Aws:/, 'http:'))
      uri.path = STREAMING_PATH
      uri.query = nil
      return uri
    rescue Ginseng::GatewayError => e
      raise classify(e)
    end

    # ⚠ **トークンはヘッダで渡す**（→ `streaming_uri`）。⚠ **経路の設定に関わらず直で受ける** —
    # 🔴 **受信にモロヘイヤを挟む理由が無い**（タグ付けは投稿の側の仕事）。
    def streaming_headers
      return direct_headers({'Accept' => 'text/event-stream'})
    end

    # `idempotency_key` は再送で使い回すもの。既定では 1 回の呼び出しにつき 1 つ作る。
    # 呼び出し側が「同じ予定の投稿」を識別できるなら（スケジューラの再実行など）、
    # その識別子を渡せばプロセスをまたいだ重複も畳める。
    #
    # ⚠ `in_reply_to_id` はチャットボットの返事（#18）。
    def post_status(text, visibility: nil, in_reply_to_id: nil, idempotency_key: SecureRandom.uuid)
      body = {status: text.to_s}
      body[:visibility] = visibility.to_s if visibility
      body[:in_reply_to_id] = in_reply_to_id.to_s if in_reply_to_id
      response = post(body, {headers: {'Idempotency-Key' => idempotency_key}})
      status = validate_status(response)
      logger.info(
        mastodon: 'post',
        status_id: status['id'],
        url: status['url'],
        visibility: status['visibility'],
        length: text.to_s.length,
        # 🔴 **投稿先と同じ数え方の長さも並べる**（#351）。⚠⚠ **`length` はコードポイントで、
        # 上限（`PostBudget`）は書記素 ＋ URL 23 字** — **422 の日に 1 行で突き合わせられない。**
        post_length: PostBudget.length(text),
        # 🔴 **モロヘイヤが足した分を毎回残す**（#351）。⚠⚠ **`/mastodon/proxy_reserve` は
        # 実測から引いた値**（→ `config/application.yaml`）だが、**辞書に多く当たる原稿ほど
        # 足される分が増え、辞書もこちらの見ていないところで増える** —
        # ⚠ **1 回測って終わりにならない形にする。**
        proxy_added: proxy_added(text, status),
        # 🔴 **経路をログに出す**（#124）。⚠⚠ **「モロヘイヤを通っていない」ことに
        # 3 週間気付かなかったのは、投稿が 200 で返り、ログにも成功としか出ていな
        # かったから。**⚠ **経路の間違いは投稿の失敗として現れない。**
        mulukhiya: mulukhiya_enable?,
      )
      return response
    rescue Ginseng::GatewayError => e
      raise classify(e)
    end

    private

    # 🔴 **モロヘイヤが足した分**（#351）。⚠ **応答の `content` が「足された後の本文」**
    # なので、**読み取り権は要らない**（🔴 **`/api/v1/statuses/:id/source` は `read` が要るが、
    # 投稿そのものの応答は `write` で返る**）。
    #
    # ⚠ **迂回しているときは `nil`**（**モロヘイヤが何もしていないので測る対象が無い**）。
    #
    # 🔴🔴 **ここで例外を上げない。**⚠⚠ **投稿は既に成功している** — **記録の都合で
    # 「成功した投稿が失敗した」に化けさせない**（fail-open）。⚠ **`PostingJob` はこの先で
    # `record(:success)` と `notify` へ進む**ので、**ここで落ちると履歴も監視も巻き添えになる。**
    def proxy_added(text, status)
      return nil unless mulukhiya_enable?
      # ⚠ **`content` を持たない応答も通す**（🔴 **本物の Status は必ず持つ**が、
      # **前段が返す 200 の作り物は持たない** — → `validate_status`）。
      return nil if status['content'].blank?
      final = Text.from_html(status['content'])
      return nil if final.empty?
      added = PostBudget.length(final) + mention_loss(status) - PostBudget.length(text)
      return warn_over_reserve(added) if added >= 0
      # 🔴🔴 **負の値は記録しない**（#351）。⚠⚠ **モロヘイヤが字数を減らすことは無い**ので、
      # **負なら応答の HTML から本文を戻しきれていない** — ⚠ **黙って混ぜると分布ごと
      # 信用できなくなる。**🔴 **「知らない形が来た」を 1 行として見えるようにする。**
      #
      # 🔴🔴 **欄の名前を変える**（Codex の P2）。⚠⚠ **`proxy_added` のままだと、この診断の行を
      # `RehearsalReport#count_post` が拾い、捨てたはずの負の値が分布へ入る** —
      # ⚠ **歯止めが、歯止めようとした値を自分で流し込む形になっていた。**
      logger.warn(mastodon: 'post', message: 'proxy_added is negative', rejected_length: added)
      return nil
    rescue => e
      logger.warn(mastodon: 'post', message: 'proxy_added failed', error: e.class.to_s)
      return nil
    end

    # 🔴 **予約を超えたら 1 行残す**（#351）。
    #
    # ⚠⚠ **`/mastodon/proxy_reserve` は「原稿に許される長さ」を決める根拠**（`PostBudget#limit`）
    # なので、🔴 **超えたまま気付かないと、上限に近い原稿で 422 になり、その枠が消える**
    # （`PERMANENT_STATUSES` なので再送しない）。
    #
    # ⚠ **この 1 本は落とさない** — **3000 字にはまだ遠い**。⚠⚠ **止めるのではなく、
    # 線が合っていないことを見せる。**🔴 **2026-09-24 に予約 100 が実測 159 に負けていた**のに
    # 誰も気付かなかったのは、**超えたことを言う口がどこにも無かったから。**
    #
    # 🔴 **`positive?` で条件を絞らない**（Codex の P2 と同じ形）— ⚠⚠ **予約が 0 なら
    # `PostBudget` は 1 字も取っていない** ＝ **いちばん見たい状態。**
    #
    # ⚠ **欄名に `proxy_added` を使わない** — 🔴 **`RehearsalReport#count_post` が拾い、
    # 集計へ二重に入る**（**同じ形で 1 度踏んでいる**）。
    def warn_over_reserve(added)
      reserve = optional_config('/mastodon/proxy_reserve', 0).to_i
      return added unless added > reserve
      logger.warn(mastodon: 'post', message: 'proxy_added exceeds the reserve',
        exceeded_length: added, reserve: reserve)
      return added
    end

    # 🔴 **リモートのメンションは HTML から戻らない**（#351・Codex の P2）。
    #
    # ⚠⚠ **Mastodon は `@alice@remote.example` を「見える文字は `@alice` だけ」の h-card で返す**
    # （`<a class="mention">@<span>alice</span></a>`）ので、**タグを剥がすとドメインが消える。**
    # ⚠ **送った側には残っているので差が縮み、負の値になりうる。**
    #
    # ✅ **応答の `mentions` から戻す** — **`acct` と `username` の差 ＝ 消えた `@domain` の長さ。**
    # ⚠ **同じ相手を 2 回書いた回は 1 回ぶんしか戻らない**（🔴 **`mentions` は相手ごとに 1 件**）。
    #
    # ⚠⚠ **いまの投稿にメンションは 1 件も無い**（実測・**原稿 606 本 ＋ 曲 4,305 行で 0 件**）—
    # 🔴 **踏むのは #18 のチャットボットから**（**返信は必ず相手を名指しする**）。
    def mention_loss(status)
      mentions = status['mentions']
      return 0 unless mentions.is_a?(Array)
      return mentions.sum do |mention|
        next 0 unless mention.is_a?(Hash)
        PostBudget.length(mention['acct']) - PostBudget.length(mention['username'])
      end
    end

    # 🔴 **200 で status でないものが返る形を弾く**（#272）。
    #
    # ⚠⚠ **httparty は対応していない Content-Type ではボディを String のまま返す。**
    # ⚠ **`HTTParty::Response#[]` は `parsed_response` に委譲する**ので、**200 の HTML が
    # 返ると `response['id']` は `String#[]('id')`** ＝ **HTML の中に `id` の 2 文字が
    # あれば `"id"`、無ければ `nil`。**🔴 **どちらも例外にならない。**
    #
    # ⚠⚠ **その先で `PostingJob` が `record(:success)` と `notify` まで進む** —
    # **投稿は 1 通も出ていないのに、監視は緑・履歴は消費済み**（#41）。
    #
    # 🔴 **踏むのは前段が 200 で非 JSON を返す形**（モロヘイヤ／nginx のメンテページ、
    # vhost の誤ルーティング）。⚠ **502 / 503 は `GatewayError` になるので対象外。**
    #
    # ⚠ **同じ形を一度経験している**（#124）— **投稿が 200 で返り、ログにも成功と
    # しか出ていなかったので、モロヘイヤを通っていないことに 3 週間気付かなかった。**
    #
    # ⚠⚠ **`id` まで見る。**🔴 **`Hash` かどうかだけでは、200 で
    # `{"status":"maintenance"}` を返す前段を通してしまう** — ⚠ **`id` は
    # `PostingJob` が `status_id` としてログに書き、`notify` が履歴を進める根拠でもある。**
    def validate_status(response)
      parsed = parsed_response(response)
      return parsed if parsed.is_a?(Hash) && parsed['id'].present?
      raise_unexpected(parsed.class.to_s)
    end

    # 🔴 **本文が読めないことも「status ではない」に倒す**（#272・Codex の P2）。
    #
    # ⚠⚠ **`Content-Type` が `application/json` なら httparty は `JSON.parse` を通す**
    # ので、**切れた本文や素のテキストは `JSON::ParserError` になる**（実測）。
    # ⚠ **`post_status` は `Ginseng::GatewayError` しか rescue しない**ので、
    # 🔴 **その例外は分類も警告も通らずに外へ出ていた** — ⚠⚠ **`bin/makoto post` の
    # rescue も素通りする**（`PostingJob` は `rescue => e` で受けるので枠は落ちるだけ）。
    #
    # ⚠ **パーサの例外クラスを並べない**（`JSON` / `MultiXml` / `CSV`）。🔴 **httparty が
    # `Content-Type` を 1 つ足した日に、並べた側が黙って古くなる。**⚠⚠ **ここは
    # `response.parsed_response` を 1 回呼ぶだけのメソッド**なので、**取りこぼす
    # 例外のほうが害が大きい。**
    #
    # ⚠ **握り潰さない** — 🔴 **例外のクラスを `type` に出す**ので、**ログには
    # `String` ではなく `JSON::ParserError` と残る。**
    def parsed_response(response)
      return response.parsed_response
    rescue => e
      raise_unexpected(e.class.to_s)
    end

    # ⚠ **本文は載せない**（HTML が丸ごとログに出る）。⚠⚠ **型だけで十分に区別できる**
    # （→ `CureApiService#report_malformed`・#105 で決めた形）。
    # ⚠ **経路も出す** — 🔴 **誤ルーティングはモロヘイヤの側で起きる**（#124）。
    def raise_unexpected(type)
      logger.warn(mastodon: 'post', message: 'unexpected response shape',
        type: type, mulukhiya: mulukhiya_enable?)
      # ⚠⚠ **型を例外メッセージの末尾に置かない。**🔴 **`GatewayError#source_status` は
      # `message` の末尾 3 桁を上流のステータスとして読む**ので、**末尾に数字が来る
      # 書き方をすると `classify` の分類が化ける。**⚠ **型はログの側に出してある。**
      raise Ginseng::GatewayError, 'mastodon returned an unexpected shape'
    end

    def account_ids(kind, max_pages:)
      id = URI.encode_www_form_component(account['id'].to_s)
      path = "/api/v1/accounts/#{id}/#{kind}?limit=80"
      ids = []
      max_pages.times do
        page, path = follower_page(path)
        ids.concat(page)
        return ids unless path
      end
      raise Ginseng::GatewayError, "mastodon: #{kind} exceed #{max_pages} pages"
    rescue Ginseng::GatewayError => e
      raise classify(e)
    end

    def relationship_action(account_id, action)
      id = URI.encode_www_form_component(account_id.to_s)
      response = http.post("/api/v1/accounts/#{id}/#{action}", {
        headers: direct_headers,
        host_validator: ->(host) {host == http.base_uri.host},
      })
      body = response.parsed_response
      raise_unexpected(body.class.name) unless body.is_a?(Hash)
      return body
    rescue Ginseng::GatewayError => e
      raise classify(e)
    end

    # アカウントの一覧（フォロワー・フォロー中）の 1 ページ。⚠ **ID の配列と、次のページのパス（無ければ nil）を返す。**
    def follower_page(path)
      response = http.get(path, {
        headers: direct_headers,
        host_validator: ->(host) {host == http.base_uri.host},
        follow_redirects: true,
      })
      body = response.parsed_response
      raise_unexpected(body.class.name) unless body.is_a?(Array)
      ids = body.filter_map {|follower| follower['id']&.to_s if follower.is_a?(Hash)}
      return ids, next_page(response.headers['link'])
    end

    # `Link` の `rel="next"` を、同じホストのパスとクエリにして返す。⚠ **無ければ nil（最後のページ）。**
    #
    # 🔴 **別ホスト・読めない `next` は例外にする**（v1.0.0 のリリース前レビュー）。⚠⚠ nil にすると
    # 「最後のページ」と区別が付かず、途中までの一覧を全部として返す（門が 81 人目以降に「フォローしてね」を
    # 返し、フォローの突き合わせが外しにかかる）。⚠ 別ホストは辿らない（トークンを渡さない）。
    def next_page(link)
      found = link.to_s.split(',').find {|part| part.include?('rel="next"')}
      return nil unless found
      uri = URI.parse(found[/<([^>]+)>/, 1].to_s)
      unless uri.host == http.base_uri.host
        raise Ginseng::GatewayError, 'mastodon: next page on another host'
      end
      return [uri.path, uri.query].compact.join('?')
    rescue URI::InvalidURIError
      raise Ginseng::GatewayError, 'mastodon: unreadable next page'
    end

    # モロヘイヤを迂回して Mastodon 本体を直に叩くためのヘッダ。
    #
    # ⚠ **`create_headers` は `||=` で足す**ので、先に入れておけば経路の設定に
    # 関わらずこの値が残る。
    def direct_headers(headers = {})
      return create_headers(headers.merge({'X-Mulukhiya' => package_class.full_name}))
    end

    # ⚠ 例外メッセージにトークンを載せない。上流のステータスだけを見て分類する。
    def classify(error)
      klass = PERMANENT_STATUSES[error.source_status]
      return klass.new("mastodon returned #{error.source_status}") if klass
      return error
    end
  end
end
