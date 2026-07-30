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

    # 自分自身の acct。ステージングは @test、本番は @makoto と異なるため、
    # コード側に定数として持たせない。
    def acct
      return config['/mastodon/acct']
    end

    # 疎通確認用。投稿せずにトークンの有効性とスコープを確かめられる。
    def account
      response = http.get('/api/v1/accounts/verify_credentials', {headers: create_headers})
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
      )
      return response
    rescue Ginseng::GatewayError => e
      raise classify(e)
    end

    private

    # ⚠ 例外メッセージにトークンを載せない。上流のステータスだけを見て分類する。
    def classify(error)
      klass = PERMANENT_STATUSES[error.source_status]
      return klass.new("mastodon returned #{error.source_status}") if klass
      return error
    end
  end
end
