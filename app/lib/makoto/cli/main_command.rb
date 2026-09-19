module Makoto
  class MainCommand < Thor
    include Package

    # ⚠ **痕跡の時刻がこのプロセスの「いま」より後ろにあるときの印**（#154 →
    # `format_elapsed`）。🔴 **経過が負になる** ＝ **常駐のほうが未来に居る。**
    AHEAD_OF_PROCESS = 'ahead of this process'.freeze

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

    desc 'morning SUBCOMMAND', '朝挨拶の下見（#17）'
    subcommand 'morning', MorningCommand

    desc 'song SUBCOMMAND', '曲紹介の下見（#16）'
    subcommand 'song', SongCommand

    desc 'live SUBCOMMAND', 'バースデーライブの並び・枠の下見'
    subcommand 'live', LiveCommand

    desc 'rehearsal SUBCOMMAND', 'リハーサルの結果の集計（#110）'
    subcommand 'rehearsal', RehearsalCommand

    desc 'status', '常駐プロセスの健全性を表示（監視から叩く口）'
    long_desc <<~TEXT
      終了コード: 0 = 健全 / 1 = 異常（復旧させる）/ 2 = 警告（人が見る）

      ⚠ 生死だけでなく「仕事をしているか」を見る。systemd はプロセスの死しか
      見ないので、常駐したまま何もしていない状態を拾えない。

      🔴 日付を騙している間は、先頭に time travel の行が出る（#174）。⚠⚠ リハーサルの
      drop-in が残っていると、次の再起動が黙って当日通しを始める（＝ 162 投稿）ので、
      ⚠ 人が最初に叩くこのコマンドで言う。撤収の確認は systemctl show makoto2 -p Environment。

      出す行は 6 つ:

      running — 生死と PID。🔴 常駐が起動時に読み込んだリビジョンも（#242）。
      ⚠⚠ git log -1 は「置いてあるもの」で、こちらは「動いているもの」。死んでいればこの 1 行だけ

      jobs — ⚠⚠ 登録された本数。「出た本数」ではない（#78）。⚠ 枠の名前も並べる（#242）

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
      travel_lines(health).each {|line| puts line}
      if health.alive?
        print_health(health)
      else
        puts 'not running'
      end
      health.errors.each {|message| warn "error: #{message}"}
      health.warnings.each {|message| warn "warning: #{message}"}
      exit health.code
    end

    private

    # ⚠ **生きているときに出す 6 行**（→ `status` の `long_desc`）。⚠⚠ **死んでいれば
    # `not running` の 1 行だけ**なので、ここは呼ばれない。
    def print_health(health)
      puts "running (PID #{health.pid}, revision #{health.revision || '(unknown)'})"
      puts "jobs: #{format_jobs(health)}"
      puts "heartbeat: #{format_age(health.heartbeat_age)}"
      puts "tick: #{format_tick(health)}"
      puts "posting: #{format_posting(health)}"
      puts "orphans: #{health.orphans&.join(', ') || '(unknown)'}"
      return nil
    end

    # 🔴 **日付を騙していることを画面の先頭で言う**（#174）。
    #
    # ⚠⚠ **`systemctl restart` は「いまのコードで上げ直す」つもりの操作**なのに、
    # 🔴 **リハーサルの drop-in が残っていると、その 1 手が当日通しを始める**
    # （⚠ **2026-08-23 に実際に踏んだ** — 162 投稿）。⚠⚠ **起動ログの `time_travel` は
    # 出ているが、再起動のたびに人が読むとは限らない。**
    #
    # ⚠ **常駐の側は自分の `ENV` からは分からない**（→ `Heartbeat.touch` が痕跡に書く）。
    # 🔴 **drop-in の env が渡るのは常駐だけ**で、⚠⚠ **あとから人が叩く CLI には付かない。**
    #
    # ⚠ **CLI 自身が騙している場合は別に言う**（#154）。🔴 **向きが逆で、経過が大きく
    # 出る** — ⚠⚠ **常駐が実時間に居るのに `heartbeat is stale` の偽の赤になる。**
    def travel_lines(health)
      lines = []
      lines.push("🔴 time travel: #{format_travel(health.travel)}") if health.travel
      lines.push("🔴 time travel (this CLI): #{format_travel(TimeTravel.describe)}") \
        if TimeTravel.active?
      return lines
    end

    def format_travel(travel)
      return "from #{travel[:start]} / scale #{travel[:scale]} / mastodon #{travel[:mastodon]}"
    end

    # ⚠ **名前が無ければ本数だけ**（#242 より前の常駐が書いた痕跡）。
    def format_jobs(health)
      return '(unknown)' unless health.jobs
      names = Array(health.job_names)
      return health.jobs.to_s if names.empty?
      return "#{health.jobs} (#{names.join(', ')})"
    end

    def format_age(seconds)
      return '(unknown)' unless seconds
      return "#{format_elapsed(seconds)} (limit #{Heartbeat.limit.round}s)"
    end

    # 最後に枠を見に行った時刻（#150）。⚠ **`Health#errors` は見ているのに、人が叩く
    # コマンドが見せていなかった。**
    #
    # 🔴 **当日に人が見るのはこの画面。**⚠⚠ **8/15〜10/31 は 1 本も投稿しない**ので、
    # ⚠ **`posting` が当てにならない 2 か月半のあいだ「動いている」を確かめる唯一の
    # 手掛かりが tick。**
    #
    # ⚠⚠ **判定の基準は「最後の tick」と「起き上がった時刻」の新しいほう**
    # （→ `Heartbeat.tick_stale?`）。🔴 **初回の tick は枠を回し終えるまで痕跡を
    # 書かない**ので、**猶予が起き上がった時刻から数えられている間は、それも出す。**
    #
    # ⚠ **最後の tick だけを出すと、画面と判定が食い違う**（Codex の指摘・PR #153）—
    # ⚠⚠ **一度動いてから再起動した常駐は、古い `ticked_at` を抱えたまま猶予が
    # 張り直される**ので、🔴 **`tick: 3600s ago (limit 300s)` と出ているのに緑**という
    # 形になる。**赤に見えるのに緑、が画面でいちばん困る。**
    def format_tick(health)
      limit = "limit #{Heartbeat.tick_limit.round}s"
      last = health.ticked_at ? format_elapsed(health.now - health.ticked_at) : 'never'
      return "#{last} (#{limit})" unless tick_grace?(health)
      return "#{last} (started #{format_elapsed(health.now - health.started_at)}, #{limit})"
    end

    # 猶予が「起き上がった時刻」から数えられているか。⚠ **`Heartbeat.tick_stale?` が
    # 新しいほうを採る条件と同じもの。**
    def tick_grace?(health)
      return false unless health.started_at
      return health.ticked_at.nil? || health.ticked_at < health.started_at
    end

    # 経過を人が読む形に。🔴 **負の数を出さない**（#154）。
    #
    # ⚠⚠ **騙した時刻の原点はプロセスごと。**⚠ **`Timecop.travel` は「そのプロセスが
    # 起動した瞬間」を `MAKOTO_FAKE_TIME` に合わせる**ので、🔴 **あとから起動した CLI は
    # 常に常駐より過去に居る** — **`now - ticked_at` が負になる。**⚠ **CLI 側に同じ env を
    # 与えても直らない**（実測・#154。**そちらも 11:58 から数え直すだけ**）。
    #
    # ⚠⚠ **数字を出さずに向きだけ言う。**🔴 **`-6360337s ago` は読めないうえに、どの
    # 上限と比べても小さい** — ⚠ **画面のいちばん赤い場所が、負の数のあいだだけ緑に見える。**
    #
    # ⚠ **直すのは画面だけ**（#154 の案 A）。⚠⚠ **CLI の原点を常駐に合わせる案（B）は
    # `TimeTravel` そのものを触る** — 🔴 **あれは「偽の日付で本番へ投稿する」を止める
    # 安全装置**なので、**11/4 より前に触らない。**
    def format_elapsed(seconds)
      return AHEAD_OF_PROCESS if seconds.negative?
      return "#{seconds.round}s ago"
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
