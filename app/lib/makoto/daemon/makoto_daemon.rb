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
      connect_db
      Scheduler.instance.exec
    rescue => e
      logger.error(daemon: app_name, error: e)
      raise
    end

    def stop
      logger.info(daemon: app_name, version: Package.version, message: 'stop')
      Scheduler.instance.shutdown
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
