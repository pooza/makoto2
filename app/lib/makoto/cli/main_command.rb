module Makoto
  class MainCommand < Thor
    include Package

    def self.exit_on_failure?
      return true
    end

    desc 'version', 'バージョンと実行環境を表示'
    def version
      puts Package.full_name
      puts "environment: #{Environment.type}"
      puts "ruby: #{RUBY_VERSION} (YJIT: #{Environment.jit? ? 'ready' : 'no'})"
      puts "database: #{Environment.db}"
    end

    desc 'config', '設定を表示（秘密情報はマスクする）'
    def config
      puts Config.instance.secure_dump.to_yaml
    end

    desc 'whoami', 'Mastodon のアカウントを表示（投稿はしない）'
    def whoami
      account = MastodonService.new.account
      puts "acct: #{account['acct']}@#{URI.parse(Config.instance['/mastodon/url']).host}"
      puts "display_name: #{account['display_name']}"
      puts "bot: #{account['bot']}"
      puts "statuses: #{account['statuses_count']}"
    rescue Ginseng::AuthError => e
      warn "認証に失敗しました（トークンかスコープを確認）: #{error_message(e)}"
      exit 1
    end

    option :visibility, type: :string, desc: 'public / unlisted / private / direct'
    desc 'post TEXT', 'Mastodon に投稿する'
    def post(text)
      status = MastodonService.new.post_status(text, visibility: options[:visibility])
      puts status['url']
    rescue Ginseng::AuthError, Ginseng::ValidateError, Ginseng::RequestError => e
      warn "投稿できませんでした（再送しても変わりません）: #{error_message(e)}"
      exit 1
    rescue Ginseng::GatewayError => e
      warn "投稿できませんでした（時間をおけば通るかもしれません）: #{error_message(e)}"
      exit 1
    end

    desc 'corpus SUBCOMMAND', '台詞コーパスの投入・確認'
    subcommand 'corpus', CorpusCommand

    desc 'track SUBCOMMAND', '曲データの投入・確認'
    subcommand 'track', TrackCommand

    desc 'message SUBCOMMAND', '原稿の追加・確認・下見'
    subcommand 'message', MessageCommand

    desc 'status', '常駐プロセスの生死を表示'
    def status
      daemon = MakotoDaemon.new
      if daemon.alive?
        puts "running (PID #{daemon.pid})"
      else
        puts 'not running'
        exit 1
      end
    end
  end
end
