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

    desc 'rehearsal SUBCOMMAND', 'リハーサルの結果の集計（#110）'
    subcommand 'rehearsal', RehearsalCommand

    desc 'status', '常駐プロセスの健全性を表示（監視から叩く口）'
    long_desc <<~TEXT
      終了コード: 0 = 健全 / 1 = 異常（復旧させる）/ 2 = 警告（人が見る）

      ⚠ 生死だけでなく「仕事をしているか」を見る。systemd はプロセスの死しか
      見ないので、常駐したまま何もしていない状態を拾えない。

      出す行は 6 つ:

      running — 生死と PID。死んでいればこの 1 行だけ

      jobs — ⚠⚠ 登録された本数。「出た本数」ではない（#78）

      heartbeat — 最後のハートビートからの経過。⚠ 止まっていればスケジューラが死んでいる

      tick — 🔴 最後に枠を見に行った時刻。⚠⚠ ハートビートとは別の rufus ジョブなので、
      tick だけが詰まってもハートビートは動き続ける（#80 の黄 7）

      posting — ⚠ 投稿が実際に出ているか。連続して落ちた本数と、最後に出た時刻（#78）

      orphans — pid ファイルに無い常駐プロセス。⚠ 不明なら (unknown)

      ⚠⚠ 8/15〜10/31 は 1 本も投稿しないので posting は当てにならない。その間に
      「動いている」を確かめる手掛かりは tick（#150）。
    TEXT
    def status
      health = Health.new
      if health.alive?
        puts "running (PID #{health.pid})"
        puts "jobs: #{health.jobs || '(unknown)'}"
        puts "heartbeat: #{format_age(health.heartbeat_age)}"
        puts "tick: #{format_tick(health)}"
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

    # 最後に枠を見に行った時刻（#150）。⚠ **`Health#errors` は見ているのに、人が叩く
    # コマンドが見せていなかった。**
    #
    # 🔴 **当日に人が見るのはこの画面。**⚠⚠ **8/15〜10/31 は 1 本も投稿しない**ので、
    # ⚠ **`posting` が当てにならない 2 か月半のあいだ「動いている」を確かめる唯一の
    # 手掛かりが tick。**
    #
    # ⚠⚠ **痕跡が無いときに `never` で終わらせない。**⚠ **判定の基準は「最後の tick」と
    # 「起き上がった時刻」の新しいほう**（→ `Heartbeat.tick_stale?`）で、
    # 🔴 **初回の tick は枠を回し終えるまで痕跡を書かない** — **起動直後の `never` は
    # 正常なので、何からの猶予を数えているのかを一緒に出す。**
    def format_tick(health)
      limit = "limit #{Heartbeat.tick_limit.round}s"
      return "#{format_seconds(health.now - health.ticked_at)} ago (#{limit})" if health.ticked_at
      return "never (#{limit})" unless health.started_at
      started = format_seconds(health.now - health.started_at)
      return "never (started #{started} ago, #{limit})"
    end

    def format_seconds(seconds)
      return "#{seconds.round}s"
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
