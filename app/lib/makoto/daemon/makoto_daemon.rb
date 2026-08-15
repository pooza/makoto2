module Makoto
  # MAKOTO の常駐プロセス。start / stop / restart / status は Ginseng::Daemon が持つ。
  # プロセスは 1 本だけで、投稿のスケジュールはこの中の Scheduler が回す。
  class MakotoDaemon < Ginseng::Daemon
    include Package

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

    def connect_db
      db = Sequel.connect(Environment.dsn)
      db.run('PRAGMA journal_mode=WAL')
      db.run('PRAGMA busy_timeout=5000')
      return db
    end
  end
end
