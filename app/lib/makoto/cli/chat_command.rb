module Makoto
  # チャットのモデレーション（#510）の運用操作。⚠ **管理コンソールを作らない決定の帰結として CLI で行う。**
  class ChatCommand < Thor
    include Package

    def self.exit_on_failure?
      return true
    end

    desc 'penalties', '悪戯の印が付いた相手と、ペナルティの期限を表示する'
    def penalties
      rows = ChatRepository.new.all_penalties
      return puts('(none)') if rows.empty?
      now = Time.now
      rows.each do |row|
        state = row[:until_at] && row[:until_at] > now ? "until #{row[:until_at]}" : 'expired'
        line = "@#{row[:acct]} marks: #{row[:marks]} #{state} reason: #{row[:reason]}"
        puts [line, row[:status_url]].compact.join(' ')
      end
    rescue Sequel::DatabaseError => e
      warn "読めませんでした。先に `rake migration:run` を実行してください: #{error_message(e)}"
      exit 1
    end

    # 🔴 **投稿しない。**LLM に返事を作らせて表示するだけ（#18・ステージングでの確かめ・指示書の手直し）。
    # ⚠ **課金がある**（1 回 約 $0.015）。⚠ 門（`ChatGate`）も通らない（回数に数えない）。
    desc 'try TEXT', '返事を作らせて表示する（投稿しない・課金あり）'
    option :thread, type: :string, desc: '前のやりとり（YAML の配列・各要素は role と content）'
    def try(text)
      unless ChatModel.enabled?
        warn 'API キーがありません（config/local.yaml の /anthropic/api_key）'
        exit 1
      end
      model = ChatModel.new
      reply = model.respond(thread_messages + [{role: 'user', content: text}])
      unless reply
        warn '返事を作れませんでした（ログを見てください）'
        exit 1
      end
      puts reply.silent? ? '(返事をしない)' : reply.text
      puts "marks: #{reply.marks.join(', ')}" unless reply.marks.empty?
      usage = reply.usage
      puts "tokens: #{usage[:input_tokens]} / #{usage[:output_tokens]}" \
        " (cache read #{usage[:cache_read]} / write #{usage[:cache_write]}・約 $#{model.cost(usage)})"
    end

    # ⚠ **印の回数も 0 に戻す**（オーナーが「間違いだった」と判断したとき）。
    desc 'forgive ACCT', '相手のペナルティと印を消す（判定の間違いを直す）'
    def forgive(acct)
      repository = ChatRepository.new
      row = repository.find_penalty_by_acct(acct)
      unless row
        warn "ペナルティの記録がありません: #{acct}"
        exit 1
      end
      repository.forgive(row[:account_id])
      puts "forgiven: @#{row[:acct]} (marks: #{row[:marks]})"
    end

    # 指示書に足す台帳の塊を表示する（#526）。⚠ 評価の道具（`tools/persona_eval/run.py`）もこれを読む。
    desc 'ledger', 'チャットボットに渡す台帳（足した設定）を表示する'
    def ledger
      text = Ledger.new.to_prompt
      return puts(text) if text
      warn "台帳がありません: #{Ledger.new.path}"
      exit 1
    end

    private

    def thread_messages
      return [] unless options[:thread]
      return YAML.load_file(options[:thread]).map do |entry|
        {role: entry.fetch('role'), content: entry.fetch('content')}
      end
    end
  end
end
