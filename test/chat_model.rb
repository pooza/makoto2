require 'tmpdir'

module Makoto
  class ChatModelTest < TestCase
    URL = 'https://api.anthropic.com/v1/messages'.freeze
    MESSAGES = [{role: 'user', content: 'おはよう！'}].freeze

    def setup
      super
      config['/anthropic/api_key'] = 'sk-ant-test'
      @model = ChatModel.new(ledger: Ledger.new('/nonexistent/ledger.md'))
    end

    def response_body(reply: '{"reply":"おはようございます。","marks":[]}', stop_reason: 'end_turn',
      stop_details: nil)
      body = {
        id: 'msg_test',
        type: 'message',
        role: 'assistant',
        model: 'claude-opus-5-5',
        content: [{type: 'text', text: reply}],
        stop_reason: stop_reason,
        stop_sequence: nil,
        usage: {
          input_tokens: 300,
          output_tokens: 160,
          cache_read_input_tokens: 5700,
          cache_creation_input_tokens: 0,
        },
      }
      body[:stop_details] = stop_details if stop_details
      return body.to_json
    end

    def stub_model(**)
      headers = {'Content-Type' => 'application/json'}
      return stub_request(:post, URL).to_return(status: 200, body: response_body(**), headers: headers)
    end

    def test_it_returns_the_reply_and_the_marks
      stub_model(reply: '{"reply":"そういうお話には、乗れません。","marks":["provoke"]}')
      reply = @model.respond(MESSAGES)

      assert_equal('そういうお話には、乗れません。', reply.text)
      assert_equal(['provoke'], reply.marks)
      assert_false(reply.silent?)
      assert_equal({input_tokens: 300, output_tokens: 160, cache_read: 5700, cache_write: 0,
        model: 'claude-opus-5-5'}, reply.usage)
    end

    # 🔴 **送る形を本物の SDK で確かめる**（Ruby の属性名は `format_` なので、ハッシュの `format:` が
    # API の `format` に乗るかは送ってみないと分からない）。
    #
    # 🔴 **台帳があれば 3 つ目の塊として足し、キャッシュの印はその最後の塊に付く**（#526）。
    def test_the_ledger_is_the_last_block
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'ledger.md')
        File.write(path, "## 食べ物\n\n| 中身 | 出どころ |\n| --- | --- |\n| いちごが大好き | 宮本 |\n")
        blocks = ChatModel.new(ledger: Ledger.new(path)).system_blocks

        assert_equal(3, blocks.size)
        assert_include(blocks.last[:text], '- いちごが大好き')
        assert_nil(blocks[1][:cache_control])
        assert_equal('ephemeral', blocks.last[:cache_control][:type])
      end
    end

    def test_it_asks_for_json_with_the_persona_at_low_effort
      stub_model
      @model.respond(MESSAGES)

      assert_requested(:post, URL) do |request|
        body = JSON.parse(request.body)

        assert_equal('claude-opus-5-5', body['model'])
        assert_equal('low', body.dig('output_config', 'effort'))
        assert_equal('json_schema', body.dig('output_config', 'format', 'type'))
        assert_equal(ChatModel::MARKS, body.dig('output_config', 'format', 'schema', 'properties', 'marks',
          'items', 'enum'))
        assert_equal(2, body['system'].size)
        assert_match(/剣崎真琴（キュアソード）として/, body['system'][0]['text'])
        assert_match(/`impersonate`/, body['system'][1]['text'])
        # ⚠ 書き手向けの注記（HTML のコメント）は渡さない。
        assert_no_match(/<!--/, body['system'].map {|block| block['text']}.join)
        # 🔴 **キャッシュの印は最後の指示書の塊だけ**（会話には付けない・2026-11-08 オーナー）。
        assert_nil(body['system'][0]['cache_control'])
        assert_equal({'type' => 'ephemeral', 'ttl' => '1h'}, body['system'][1]['cache_control'])
        assert_false(body.key?('cache_control'))
        assert_equal([{'role' => 'user', 'content' => 'おはよう！'}], body['messages'])
        assert_false(body.key?('fallbacks'))
        true
      end
    end

    # ⚠ 空の返事は失敗ではない —「返事をしない」を選んだ（#510）。
    def test_an_empty_reply_is_silence_not_failure
      stub_model(reply: '{"reply":"","marks":["impersonate"]}')
      reply = @model.respond(MESSAGES)

      assert_true(reply.silent?)
      assert_equal(['impersonate'], reply.marks)
    end

    def test_unknown_marks_are_dropped
      stub_model(reply: '{"reply":"はい。","marks":["provoke","angry"]}')

      assert_equal(['provoke'], @model.respond(MESSAGES).marks)
    end

    # 🔴 **失敗したら黙る**（2026-11-08・オーナー）。⚠ どれも nil で、例外を上げない。
    def test_a_refusal_is_silence
      details = {type: 'refusal', category: nil, explanation: nil}
      stub_model(reply: '', stop_reason: 'refusal', stop_details: details)

      assert_nil(@model.respond(MESSAGES))
    end

    def test_a_truncated_reply_is_silence
      stub_model(reply: '{"reply":"そう', stop_reason: 'max_tokens')

      assert_nil(@model.respond(MESSAGES))
    end

    def test_an_unreadable_reply_is_silence
      stub_model(reply: 'こんにちは')

      assert_nil(@model.respond(MESSAGES))
    end

    def test_an_api_error_is_silence
      body = {type: 'error', error: {type: 'invalid_request_error', message: 'bad'}}.to_json
      headers = {'Content-Type' => 'application/json'}
      stub_request(:post, URL).to_return(status: 400, body: body, headers: headers)

      assert_nil(@model.respond(MESSAGES))
    end

    def test_a_timeout_is_silence
      config['/chat/model/max_retries'] = 0
      stub_request(:post, URL).to_timeout

      assert_nil(ChatModel.new.respond(MESSAGES))
    end

    # 🔴 **キーが通らなくなったら痕跡に残す**（→ `Health#chat_warnings`）。⚠ 次に通れば消える。
    def test_a_rejected_key_is_recorded_and_cleared
      FileUtils.rm_f(Heartbeat.path)
      body = {type: 'error', error: {type: 'authentication_error', message: 'invalid x-api-key'}}.to_json
      headers = {'Content-Type' => 'application/json'}
      stub_request(:post, URL).to_return(status: 401, body: body, headers: headers)

      assert_nil(@model.respond(MESSAGES))
      assert_not_nil(Heartbeat.chat_auth_failed_at)

      WebMock.reset!
      stub_model
      @model.respond(MESSAGES)

      assert_nil(Heartbeat.chat_auth_failed_at)
    ensure
      FileUtils.rm_f(Heartbeat.path)
    end

    # 🔴 **ワークスペースに紐づいていないキーは、ヘッダーで名指しする**。
    def test_the_workspace_is_named_when_configured
      config['/anthropic/workspace_id'] = 'wrkspc_test'
      stub_model
      @model.respond(MESSAGES)

      assert_requested(:post, URL, headers: {'anthropic-workspace-id' => 'wrkspc_test'})
    end

    def test_it_is_disabled_without_a_key
      config['/anthropic/api_key'] = ' '

      assert_false(ChatModel.enabled?)
    end

    def test_cost
      assert_in_delta(0.0172, @model.cost({input_tokens: 3500, output_tokens: 160}), 0.00001)
    end

    # ⚠ キャッシュから読んだ分・書いた分は別の単価（書き込みは TTL で違う）。
    def test_cost_with_the_cache
      usage = {input_tokens: 300, output_tokens: 60, cache_read: 5700}

      config['/chat/model/cache_ttl'] = '5m'

      assert_in_delta(0.00354, @model.cost(usage), 0.00001)
      assert_in_delta(0.0309, @model.cost(usage.merge(cache_read: 0, cache_write: 5700)), 0.00001)
      config['/chat/model/cache_ttl'] = '1h'

      assert_in_delta(0.048, @model.cost(usage.merge(cache_read: 0, cache_write: 5700)), 0.00001)
    end

    def test_a_bad_cache_ttl_is_a_config_error
      config['/chat/model/cache_ttl'] = '10m'

      assert_raises(Ginseng::ConfigError) {@model.system_blocks}
    end

    # 🔴 **認証以外の失敗が続いたら痕跡に残す**（#611 → `Health#chat_warnings`）。⚠ 次に通れば消える。
    def test_failures_are_counted_and_cleared
      FileUtils.rm_f(Heartbeat.path)
      body = {type: 'error', error: {type: 'invalid_request_error', message: 'credit balance is too low'}}.to_json
      headers = {'Content-Type' => 'application/json'}
      stub_request(:post, URL).to_return(status: 400, body: body, headers: headers)

      2.times {assert_nil(@model.respond(MESSAGES))}

      assert_equal(2, Heartbeat.chat_failures)
      assert_not_nil(Heartbeat.chat_failed_since)

      WebMock.reset!
      stub_model
      @model.respond(MESSAGES)

      assert_equal(0, Heartbeat.chat_failures)
      assert_nil(Heartbeat.chat_failed_since)
    ensure
      FileUtils.rm_f(Heartbeat.path)
    end
  end
end
