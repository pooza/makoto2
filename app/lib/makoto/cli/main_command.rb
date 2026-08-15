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

    desc 'live SUBCOMMAND', 'バースデーライブの並び・枠の下見'
    subcommand 'live', LiveCommand

    desc 'status', '常駐プロセスの健全性を表示（監視から叩く口）'
    long_desc <<~TEXT
      終了コード: 0 = 健全 / 1 = 異常（復旧させる）/ 2 = 警告（人が見る）

      ⚠ 生死だけでなく「投稿を持っているか」「ハートビートが止まっていないか」を見る。
      systemd はプロセスの死しか見ないので、常駐したまま何もしていない状態を拾えない。

      ⚠⚠ jobs は「登録された本数」で「出た本数」ではない。投稿が実際に出ているかは
      posting の行を見る（#78）。
    TEXT
    def status
      health = Health.new
      if health.alive?
        puts "running (PID #{health.pid})"
        puts "jobs: #{health.jobs || '(unknown)'}"
        puts "heartbeat: #{format_age(health.heartbeat_age)}"
        puts "posting: #{format_posting(health)}"
        puts "orphans: #{health.orphans&.join(', ') || '(unknown)'}"
      else
        puts 'not running'
      end
      health.errors.each {|message| warn "error: #{message}"}
      health.warnings.each {|message| warn "warning: #{message}"}
      exit health.code
    end

    private

    def format_age(seconds)
      return '(unknown)' unless seconds
      return "#{seconds.round}s ago (limit #{Heartbeat.limit.round}s)"
    end

    # ⚠ **「一度も投稿していない」を異常に見せない。**⚠⚠ **11/1 まではこれが正常**
    # （枠はあるが、その日の原稿が無い）なので、`never` とだけ言う。
    def format_posting(health)
      last = health.posted_at ? "last success #{health.posted_at.getutc.iso8601}" : 'never posted'
      failures = "#{health.posting_failures} failures in a row (limit #{Heartbeat.failure_limit})"
      return "#{last}, #{failures}"
    end
  end
end
