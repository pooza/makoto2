module Makoto
  # チャットのモデレーション（#510）の運用操作。⚠ **管理コンソールを作らない決定の帰結として CLI で行う。**
  class ChatCommand < Thor
    include Package

    def self.exit_on_failure?
      return true
    end

    desc 'penalties', '悪戯の印が付いた相手と、ペナルティの期限を表示する'
    def penalties
      rows = repository.all_penalties
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

    # 🔴 **返事をしない相手を載せる**（#20）。⚠ 次のメンションに決まった文（`chat_block_notice`）を 1 回だけ
    # 返し、あとは黙る。⚠ **Mastodon のブロックではない**（相手のフォローは外れない・通知も届く）。
    # ⚠ ミュートでは止まらない（2026-11-09 に Mastodon 4.7.5 で確かめた → #20）。
    desc 'block ACCT', '返事をしない相手に載せる（次のメンションに 1 回だけ伝えて、あとは黙る）'
    option :note, type: :string, desc: '載せた理由（オーナーの控え・相手には伝えない）'
    def block(acct)
      found = mastodon.lookup_account(acct)
      unless found
        warn "アカウントが見つかりません: #{acct}"
        exit 1
      end
      if repository.blocked(found['id'])
        warn "もう載っています: @#{found['acct']}"
        exit 1
      end
      repository.block(found['id'], found['acct'], note: options[:note])
      puts "blocked: @#{found['acct']} (id: #{found['id']})"
    end

    desc 'unblock ACCT', '返事をしない相手から外す'
    def unblock(acct)
      # ⚠ 載せたときの acct（ローカルはホスト無し）で引けなければ、Mastodon で引き直して ID で探す。
      row = repository.find_block_by_acct(acct)
      row ||= (found = mastodon.lookup_account(acct)) && repository.blocked(found['id'])
      unless row
        warn "載っていません: #{acct}"
        exit 1
      end
      repository.unblock(row[:account_id])
      puts "unblocked: @#{row[:acct]}"
    end

    # 🔴 **外すフォローの歯止めを超えて止まったときの口**（#614・2026-11-10 オーナー判断）。⚠ 既定は見るだけ。
    # ⚠ `--apply` は歯止めを今回だけ外して突き合わせる（常駐の次の回からは、また歯止めが効く）。
    desc 'follow-sync', '返す・外すフォローを表示する（--apply で歯止めを外して 1 回だけ通す）'
    option :apply, type: :boolean, default: false, desc: '歯止めを外して実行する'
    def follow_sync
      unless options[:apply]
        to_follow, to_unfollow = syncer.preview
        return fail_with('フォロワーの一覧を引けませんでした（ログを見てください）') unless to_follow
        puts "follow: #{to_follow.size} #{to_follow.to_a.join(' ')}".strip
        puts "unfollow: #{to_unfollow.size} #{to_unfollow.to_a.join(' ')}".strip
        return puts("limit: #{config['/chat/follow/unfollow_limit']}（--apply で歯止めを外して実行）")
      end
      result = syncer.sync(force: true)
      return fail_with('フォロワーの一覧を引けませんでした（ログを見てください）') unless result
      puts "followed: #{result[:followed].size} unfollowed: #{result[:unfollowed].size}"
    end

    desc 'blocks', '返事をしない相手の一覧'
    def blocks
      rows = repository.all_blocks
      return puts('(none)') if rows.empty?
      rows.each do |row|
        puts ["@#{row[:acct]}", "since #{row[:blocked_at]}", row[:note]].compact.join(' ')
      end
    end

    private

    # ⚠ テストが差し替える（`@syncer`）。
    def syncer
      @syncer ||= FollowSync.new
      return @syncer
    end

    def fail_with(message)
      warn message
      exit 1
    end

    # ⚠ テストが差し替える（`@repository` / `@mastodon`）。
    def repository
      @repository ||= ChatRepository.new
      return @repository
    end

    def mastodon
      @mastodon ||= MastodonService.new
      return @mastodon
    end

    def thread_messages
      return [] unless options[:thread]
      return YAML.load_file(options[:thread]).map do |entry|
        {role: entry.fetch('role'), content: entry.fetch('content')}
      end
    end
  end
end
