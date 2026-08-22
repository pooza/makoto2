module Makoto
  # MAKOTO の常駐プロセス。start / stop / restart / status は Ginseng::Daemon が持つ。
  # プロセスは 1 本だけで、投稿のスケジュールはこの中の Scheduler が回す。
  class MakotoDaemon < Ginseng::Daemon
    include Package
    include ProcessIdentity

    # @param proc_dir [String] プロセスの一覧を読む場所。⚠ **テストが差し替える**
    def initialize(opts = {})
      super
      @proc_dir = opts[:proc_dir] || ProcessIdentity::PROC_DIR
    end

    # pid ファイルの常駐が生きているか。
    #
    # 🔴 **番号だけでなく身元も確かめる**（#80 の黄 6）。⚠⚠ **`Ginseng::Daemon#alive?`
    # は `Process.kill(0, pid)` しか見ない**ので、⚠ **pid が再利用されると無関係な
    # プロセスを常駐だと答える**（実測 — `sleep 300` の pid を pid ファイルに書くと
    # `running (PID 354866)` と表示された）。
    #
    # ⚠⚠ **倒れ方が静かなのが問題だった** — `run_start` が「already running」で
    # 終了し、⚠ **systemd の `Restart=always` が 5 秒ごとに叩き直す**ので、
    # 🔴 **ボットは一度も起動せず、理由もログに残らない**（warn は stderr →
    # `bin/makoto_daemon.rb` が `/dev/null` に落とす）。
    #
    # ⚠ **`run_restart` も同じ穴を踏んでいた** — `run_stop if alive?` を通って
    # ⚠⚠ **無関係なプロセスへ TERM を送る**形だった。
    # 🔴 **`super` を通さない**（#111）。⚠⚠ **上流 1.15.28 の `Ginseng::Daemon#alive?`
    # は `EPERM` も `false` に倒す**ので、⚠ **`super` を先に通すと、身元の判定へ
    # 届く前に fail-open する。**
    def alive?
      return false unless (target = pid)
      return false unless process_present?(target)
      return daemon_pid?(target, proc_dir: @proc_dir)
    end

    def command
      return nil
    end

    def motd
      return [
        "#{Package.full_name} (#{Environment.type})",
        ('Ruby YJIT: Ready' if Environment.jit?),
      ].compact.join("\n")
    end

    def start(args = [])
      logger.info(daemon: app_name, version: Package.version, message: 'start')
      # 🔴 **設定を起動時に 1 回検証する**（#99）。⚠ **止めない**（→ `validate_config`）。
      validate_config
      # ⚠ 登録より先に繋ぐ。原稿を引く口（`MessageSelector`）が接続を要る。
      connect_db
      register_jobs
      # ⚠ 監視の口は登録のあとに開ける（#84）。⚠⚠ **先に開けると、まだ 0 本の
      # `jobs` を見た `/healthz` が「投稿を 1 本も持たない」と赤くする。**
      #
      # 🔴 **起き上がったことを、口を開ける前に記録する**（PR #98 の Codex 指摘）。
      # ⚠⚠ **初回の tick は枠を全部回し終えるまで痕跡を書かない**ので、これが無いと
      # ⚠ **口を開けた直後から「tick が止まっている」と赤くなる**
      # （→ `Heartbeat.record_start`）。
      record_start
      monitor_server.start
      # 🔴 **トークンが生きているかを起き上がりで 1 回見る**（#106）。
      # ⚠ **投稿はしないので副作用は無い。**
      verify_credentials
      Scheduler.instance.exec
    rescue => e
      logger.error(daemon: app_name, error: e)
      raise
    end

    # ⚠ `run_start` の trap から同じインスタンスの `stop` が呼ばれる（→ Ginseng::Daemon）
    # ので、⚠⚠ **常駐が畳まれるときに監視の口も一緒に閉じる。**
    def stop
      logger.info(daemon: app_name, version: Package.version, message: 'stop')
      monitor_server.stop
      Scheduler.instance.shutdown
    end

    def monitor_server
      @monitor_server ||= MonitorServer.new
      return @monitor_server
    end

    # 常駐が回す投稿を並べる。
    #
    # ⚠ **投稿の中身はここに書かない。**何を投稿するかは各機能が自分の `PostingJob`
    # を作って持つ（→ `Scheduler`）。ここは並べるだけ。
    # ⚠ **`Scheduler#exec` より前に呼ぶこと**（登録が 0 本だと tick そのものが作られない）。
    def register_jobs
      Scheduler.instance.register(Announcement.new.job)
      # ⚠ ライブは 4 本（前日増量・開始告知・8 時間の進行・終了告知）。
      # ⚠⚠ **どれも枠は毎日あるが、ライブ当日以外は何も返さない**（→ Live）。
      Live.new.jobs.each {|job| Scheduler.instance.register(job)}
      return Scheduler.instance
    end

    private

    # ⚠⚠ **ここから 3 つは上流（`ginseng-core`）の穴を自分の箱で塞いだもの**
    # （#111 ／ 上流は `pooza/ginseng-core#509` / `#510` で修正済み）。
    # 🔴 **`bundle update ginseng-core` で追随したら、この 3 つを消す**（→ #101）。
    # ⚠ **33 commits の追随ごと持ってくるのは 11/4 の前には危険**（`HTTP#repeat` の
    # 再送対象・`Config#reload`・`format: uri` の厳格化が同梱される）ので、
    # **ここだけ先に塞いでいる**（→ docs/CLAUDE.md「先に自分の箱を塞ぐ」）。

    # その番号のプロセスが在るか。
    #
    # 🔴 **`EPERM` は「居るが signal を送れない」＝生きている**（#111）。
    # ⚠⚠ **上流はここを `false` に倒していた**ので、⚠ **他人の権限で走っている常駐が
    # 「死んでいる」と読まれ、`run_start` が二重に起動しうる。**
    def process_present?(target)
      signal(target, 0)
      return true
    rescue Errno::ESRCH
      return false
    rescue Errno::EPERM
      return true
    end

    # 🔴 **`TERM` を送ってから pid ファイルを消す**（#111）。
    #
    # ⚠⚠ **上流は先に `remove_pid` してから `Process.kill('TERM')` を呼び、`EPERM` を
    # 拾っていない** — 🔴 **pid ファイルだけ消えてプロセスは生き残る ＝ 孤児が確定する。**
    # ⚠ **旧実装が孤児を 11 日分撒いた**（→ docs/CLAUDE.md「プロセスの寿命を設計に
    # 含める」）ので、⚠⚠ **迷ったら孤児を作らないほうへ倒す。**
    def run_stop
      unless (target = pid)
        warn 'PID file not found. Is the daemon started?'
        exit 1
      end
      # 🔴 **送る前に身元を確かめる**（#162）。⚠⚠ **`alive?` には #80 の黄 6（pid の
      # 再利用）と黄 3（`0`）を塞いだが、`run_stop` はその `alive?` を通らない** —
      # ⚠ **`run_restart` は `run_stop if alive?` なので守られていたが、
      # `bin/makoto_daemon.rb stop` を直に叩く経路が素通しだった。**
      #
      # 🔴 **`pid` は `File.read(pid_file).to_i` なので、空も壊れた文字列も `0`。**
      # ⚠⚠ **`0` は truthy なので上の `unless` を抜け、`Process.kill('TERM', 0)` ＝
      # 呼び出し元のプロセスグループ全体に TERM を送る。**⚠ **人が手で止める経路と
      # 復旧のラッパーが踏む**（systemd は `ExecStop` を書いていないので通らない）。
      unless daemon_pid?(target, proc_dir: @proc_dir)
        # ⚠ **`ESRCH` の枝と同じ扱い。**⚠⚠ **pid ファイルは掃除する** — **残すと
        # `run_start` が「already running」で無言終了する**（#80 の黄 6 で踏んだ形）。
        remove_pid
        warn "PID file found, but PID #{target} is not #{app_name}."
        return nil
      end
      signal(target, 'TERM')
      remove_pid
    rescue Errno::ESRCH
      # ⚠ 居ないなら pid ファイルは掃除してよい。**残すと `run_start` が
      # 「already running」で無言終了する。**
      remove_pid
      warn 'PID file found, but process was not running.'
    rescue Errno::EPERM
      # 🔴 **消さない。**⚠⚠ **消した瞬間に孤児が確定する**（次の起動が別プロセスを立て、
      # 元のプロセスは誰も知らないまま投稿し続ける）。
      warn "#{app_name} is running (PID #{target}) but could not be signalled. PID file kept."
      exit 1
    end

    # ⚠ **`Process.kill` を直に呼ばずここを通す。**⚠⚠ **テストが差し替える継ぎ目**で、
    # **これが無いと `EPERM` を作るのに他人のプロセスへ本物の signal を送ることになる。**
    def signal(target, value)
      return Process.kill(value, target)
    end

    # 設定を起動時に 1 回検証する（#99）。
    #
    # ⚠⚠ **`rake config:lint` は開発機で流すもの**で、⚠ **稼働ホストにしか無い
    # `config/local.yaml` は検証を一度も通っていなかった。**
    #
    # 🔴 **通らなくても常駐は止めない**（2026-08-21・オーナー判断）。⚠⚠ **止めると
    # systemd の `Restart=always` が 5 秒ごとに叩き直す形**になり、⚠ **11/4 当日に
    # 踏むと復旧の時間が要る。**⚠⚠ **代わりに `/healthz` を赤にする**（→ `Health`）。
    #
    # ⚠ **ここで例外にしない**のは `record_start` と同じ扱い（痕跡が書けないことで
    # 常駐が上がらないのを避ける）。
    def validate_config
      found = config.validation_errors
      return found if found.empty?
      logger.error(daemon: app_name, config: 'invalid', count: found.size, errors: found)
      return found
    rescue => e
      # ⚠⚠ **検証そのものが落ちても常駐は上げる。**⚠ schema が読めないだけで
      # ボットが動かなくなるほうが痛い。
      logger.error(daemon: app_name, config: 'unverified', error: e)
      return []
    end

    # トークンの失効を起き上がりで見に行く（#106）。⚠ **`verify_credentials` は
    # 投稿しない**ので、**叩いても当日の並びに影響しない。**
    #
    # 🔴 **これが無いと、失効に気付くのが 11/3 になる。**⚠ **8/15〜10/31 は 1 本も
    # 投稿しない**ので痕跡が出ず、⚠⚠ **予告は 1 日 1 枠なので `failure_limit: 3` に
    # 届くのに 3 日かかる**（11/1 → 11/3）。**気付いたときには前日。**
    #
    # ⚠⚠ **別スレッドで投げる。**🔴 **ここで待つと最悪 93 秒**（timeout 30 秒 × 再送 3）
    # **初回の tick が遅れ、枠の頭 ＋ 拾う幅を過ぎて 1 枠落ちる**（→ #47 / #92）。
    #
    # ⚠ **失効（401 / 403）とそれ以外を分ける。**⚠⚠ **「Mastodon が落ちている」が
    # 「トークンが死んでいる」に化けると、当日いちばん困る**（→ #124 と同じ形）。
    # ⚠ **どちらでも常駐は止めない**（痕跡が書けないときと同じ扱い）。
    #
    # ⚠ **`/healthz` には載せない**（#106 で明示）。**Mastodon 側の一時的な不調で
    # 「復旧させる」が叩かれる**ので、**ログに残すだけにする。**
    #
    # @return [Thread] ⚠ テストが待ち合わせに使う
    def verify_credentials
      return Thread.new do
        account = MastodonService.new.account
        logger.info(mastodon: 'verify_credentials', acct: account['acct'],
          statuses: account['statuses_count'])
      rescue Ginseng::AuthError => e
        logger.error(mastodon: 'verify_credentials', message: 'token is not valid', error: e)
      rescue => e
        logger.warn(mastodon: 'verify_credentials', message: 'could not verify the token', error: e)
      end
    end

    # 起き上がったことを痕跡に残す（→ `Heartbeat.record_start`）。
    #
    # 🔴 **書けなくても常駐は止めない**（リリース前レビューの黄 1）。⚠⚠ **痕跡は
    # 観測のためのもの**なので、**`Scheduler` 側の `record_tick` / `touch` はどちらも
    # rescue の内側に置いてある**（`test/scheduler.rb` が「痕跡が書けなくても tick は
    # 止めない」を保証している）。⚠ **ここだけ素で呼ぶと、`tmp/run` が書けないだけで
    # `start` の rescue が再送出し**、🔴 **監視の口も投稿も立ち上がらないまま
    # systemd が 5 秒ごとに叩き直す**（警告は stderr → `/dev/null`）。
    def record_start
      Heartbeat.record_start
      return nil
    rescue => e
      logger.error(daemon: app_name, error: e)
      return nil
    end

    # ⚠ **投稿の経路が使うのと同じ接続を掴む**（#80 の緑 5）。
    #
    # 🔴 **以前はここで別に `Sequel.connect` して PRAGMA を当てていたが、その接続は
    # 誰も使っていなかった** — ⚠⚠ **原稿を引く口が使うのは `Database.connection` の
    # ほう**なので、**WAL も busy_timeout も効いていなかった。**⚠ **PRAGMA は
    # `Database.connect` に移した**ので、**この先増やすぶんも空振りしない。**
    def connect_db
      return Database.connection
    end
  end
end
