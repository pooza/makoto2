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
  end
end
