module Makoto
  # 台詞コーパスの運用操作。管理コンソールを作らない決定の帰結として、
  # 投入も確認も CLI から行う。
  class CorpusCommand < Thor
    include Package

    def self.exit_on_failure?
      return true
    end

    option :dir, type: :string, desc: '取り込み元のディレクトリ（既定は /corpus/dir）'
    desc 'import', '旧 DB のダンプ（JSON）を投入する。何度実行してもよい'
    def import
      counts = CorpusImporter.new(options[:dir]).exec
      counts.each {|key, value| puts "#{key}: #{value}"}
    rescue Sequel::DatabaseError => e
      warn "投入できませんでした。先に `rake migration:run` を実行してください: #{error_message(e)}"
      exit 1
    rescue Ginseng::NotFoundError => e
      warn "取り込み元が見つかりません（var/ はコミットしないので手元に取り寄せる）: #{error_message(e)}"
      exit 1
    end

    desc 'stat', '投入済みコーパスの件数を表示する'
    def stat
      quotes = QuoteRepository.new
      messages = MessageRepository.new
      puts "quote: #{quotes.count}"
      puts "  応答可: #{quotes.respondable_count}"
      quotes.forms.each do |name, id|
        puts "    #{name}: #{quotes.respondable(form: id).count}"
      end
      puts "message: #{messages.count}"
      messages.count_by_type.sort_by {|_, count| -count}.each do |type, count|
        puts "  #{type}: #{count}"
      end
    rescue Sequel::DatabaseError => e
      warn "読めませんでした。先に `rake migration:run` を実行してください: #{error_message(e)}"
      exit 1
    end
  end
end
