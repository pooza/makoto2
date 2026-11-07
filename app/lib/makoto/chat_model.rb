require 'anthropic'

module Makoto
  # チャットボットの返事を LLM に作らせる口（#18）。⚠ **呼ぶかどうかは決めない**（→ `ChatGate`）。
  # ⚠ **投稿もしない** — 返事の本文と悪戯の印を返すだけ。
  #
  # ## 🔴 返事と印を 1 回の呼び出しで受ける（2026-11-08・オーナー）
  #
  # structured outputs で `{reply, marks}` を返させる。⚠⚠ **印のために呼び出しを増やさない**（#510）。
  # ⚠ 形の指示は `config/chat/reply_format.md`、人柄の指示は `config/chat/persona.md`。
  # 🔴 **評価の道具（`tools/persona_eval/run.py`）も同じ 2 つを読む** — 本番と評価で指示書をずらさない。
  #
  # ## 🔴 失敗したら黙る（2026-11-08・オーナー）
  #
  # API の失敗・時間切れ・拒否（`stop_reason: :refusal`）・上限での打ち切り・読めない JSON は、
  # **どれも `nil` を返す**（呼び出し側は何も投稿しない）。⚠ ログと Sentry には残す。
  # ⚠⚠ **例外を上げない** — 受信の口（`MentionListener`）を止めない。
  # ⚠ **空の返事（`reply: ""`）は失敗ではない** —「返事をしない」を選んだ結果（#510）。`Reply#silent?` で見る。
  #
  # ⚠ **サーバー側のフォールバック（`fallbacks`）は付けない。**拒否されたら別のモデルが真琴として答える
  # 形になり、「全機能で同じモデル」（docs「LLM プロバイダとモデル」）と「失敗したら黙る」の両方に反する。
  #
  # ⚠⚠ **相手の本文も返事の本文もログに出さない**（長さと印と使用量だけ）。
  class ChatModel
    include Package

    # 悪戯の印（#510）。⚠ `config/chat/reply_format.md` の一覧と揃える。
    MARKS = ['provoke', 'backstage', 'impersonate'].freeze

    SCHEMA = {
      type: 'object',
      properties: {
        reply: {type: 'string'},
        marks: {type: 'array', items: {type: 'string', enum: MARKS}},
      },
      required: ['reply', 'marks'],
      additionalProperties: false,
    }.freeze

    PROMPT_FILES = ['config/chat/persona.md', 'config/chat/reply_format.md'].freeze

    Reply = Data.define(:text, :marks, :usage) do
      # 「返事をしない」を選んだ（空の返事）。⚠ 失敗ではない。
      def silent?
        return text.strip.empty?
      end
    end

    # @param client [Anthropic::Client, nil] ⚠ テストが差し替える
    def initialize(client: nil)
      @client = client
    end

    # API キーが置いてあるか。⚠ **無ければチャットボットは動かない**（受信は続く）。
    def self.enabled?
      config = Config.instance
      return false unless config.key?('/anthropic/api_key')
      return !config['/anthropic/api_key'].to_s.strip.empty?
    end

    # @param messages [Array<Hash>] `{role:, content:}` の並び。⚠ **最後は相手の投稿（`user`）**
    # @return [Reply, nil] ⚠ **失敗したら nil**（→ クラスの冒頭）
    def respond(messages)
      response = client.messages.create(**params(messages), request_options: request_options)
      return parse(response)
    rescue Anthropic::Errors::APIError => e
      logger.error(chat: 'model', message: 'request failed', error_class: e.class.name,
        status: e.respond_to?(:status) ? e.status : nil, error: e)
      report_error(e, chat: 'model')
      return nil
    end

    def params(messages)
      return {
        model: setting('name'),
        max_tokens: setting('max_tokens'),
        system_: system_blocks,
        output_config: {
          effort: setting('effort'),
          format: {type: :json_schema, schema: SCHEMA},
        },
        messages: messages,
      }
    end

    # ⚠ **起動時に一度だけ読む**（書き換えたら再起動）。⚠ HTML のコメントは渡さない（書き手向けの注記）。
    def system_blocks
      @system_blocks ||= PROMPT_FILES.map do |path|
        text = File.read(File.join(Environment.dir, path))
        {type: 'text', text: text.gsub(/<!--.*?-->\s*/m, '').strip}
      end
      return @system_blocks
    end

    # 使用量の見積もり（USD）。⚠ ログで見直すための目安で、請求額ではない。
    def cost(usage)
      input = usage[:input_tokens].to_i * setting('price/input').to_f
      output = usage[:output_tokens].to_i * setting('price/output').to_f
      return ((input + output) / 1_000_000).round(5)
    end

    private

    def client
      @client ||= Anthropic::Client.new(
        api_key: config['/anthropic/api_key'],
        timeout: duration(setting('timeout')),
        max_retries: setting('max_retries'),
      )
      return @client
    end

    # 🔴 **ワークスペースに紐づいていないキーは、使うワークスペースをヘッダーで名指しする**
    # （無いと 400「This API key is not scoped to a workspace」・2026-10-20 に評価の道具で踏んだ）。
    def request_options
      workspace = optional_config('/anthropic/workspace_id')
      return {} if workspace.to_s.empty?
      return {extra_headers: {'anthropic-workspace-id' => workspace.to_s}}
    end

    def parse(response)
      usage = usage_of(response)
      unless response.stop_reason == :end_turn
        return failed(response, usage, message: "stopped: #{response.stop_reason}")
      end
      body = response.content.find {|block| block.type == :text}&.text
      data = JSON.parse(body.to_s)
      reply = Reply.new(text: data['reply'].to_s, marks: Array(data['marks']) & MARKS, usage: usage)
      logger.info(chat: 'model', length: reply.text.length, marks: reply.marks, **usage,
        cost: cost(usage))
      return reply
    rescue JSON::ParserError, NoMethodError => e
      # ⚠⚠ **例外の文を渡さない** — `JSON::ParserError` は入力の抜粋（返事の本文）を含む。
      return failed(response, usage, message: 'unreadable reply', error_class: e.class.name)
    end

    def failed(response, usage, **fields)
      category = response.stop_details&.category if response.stop_reason == :refusal
      logger.warn(chat: 'model', **fields, category: category, **usage.to_h, cost: cost(usage.to_h))
      report_error(Ginseng::GatewayError.new("chat model: #{fields[:message]}"), chat: 'model')
      return nil
    end

    def usage_of(response)
      usage = response.usage
      return {} unless usage
      return {
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        model: response.model.to_s,
      }
    end

    def setting(key)
      return config["/chat/model/#{key}"]
    end

    def duration(value)
      seconds = Fugit::Duration.parse(value.to_s)&.to_sec
      raise Ginseng::ConfigError, "chat: bad model timeout '#{value}'" unless seconds&.positive?
      return seconds
    end
  end
end
