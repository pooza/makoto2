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
    def account
      response = http.get('/api/v1/accounts/verify_credentials', {headers: direct_headers})
      return response.parsed_response
    rescue Ginseng::GatewayError => e
      raise classify(e)
    end

    # `idempotency_key` は再送で使い回すもの。既定では 1 回の呼び出しにつき 1 つ作る。
    # 呼び出し側が「同じ予定の投稿」を識別できるなら（スケジューラの再実行など）、
    # その識別子を渡せばプロセスをまたいだ重複も畳める。
    def post_status(text, visibility: nil, idempotency_key: SecureRandom.uuid)
      body = {status: text.to_s}
      body[:visibility] = visibility.to_s if visibility
      response = post(body, {headers: {'Idempotency-Key' => idempotency_key}})
      logger.info(
        mastodon: 'post',
        status_id: response['id'],
        url: response['url'],
        visibility: response['visibility'],
        length: text.to_s.length,
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
