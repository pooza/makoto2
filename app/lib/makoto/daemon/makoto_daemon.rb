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
    def alive?
      return false unless super
      return daemon_pid?(pid, proc_dir: @proc_dir)
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
      # ⚠ 登録より先に繋ぐ。原稿を引く口（`MessageSelector`）が接続を要る。
      connect_db
      register_jobs
      # ⚠ 監視の口は登録のあとに開ける（#84）。⚠⚠ **先に開けると、まだ 0 本の
      # `jobs` を見た `/healthz` が「投稿を 1 本も持たない」と赤くする。**
      monitor_server.start
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
