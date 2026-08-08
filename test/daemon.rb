module Makoto
  class DaemonTest < TestCase
    def setup
      @daemon = MakotoDaemon.new
    end

    def test_pid_file
      assert_equal(File.join(Environment.dir, 'tmp/pids/MakotoDaemon.pid'), @daemon.pid_file)
    end

    # 起動時のバナーとログにバージョンが出ること。動いているコードが判別できないと
    # デプロイ・検証で事故る。
    def test_motd
      assert_include(@daemon.motd, Package.version)
      assert_include(@daemon.motd, Environment.type)
    end

    # ⚠⚠ **常駐が投稿を 1 本も持たない状態を検知する。**登録が 0 本だと Scheduler は
    # tick そのものを作らず、「常駐しているが何もしていない」になる（→ #10 / #14）。
    # ⚠ どの投稿かは Announcement 側のテストが見る。ここは**並んでいること**だけ。
    def test_register_jobs
      Scheduler.instance.clear

      @daemon.register_jobs

      assert_equal(1, Scheduler.instance.send(:jobs))
    ensure
      Scheduler.instance.clear
    end
  end
end
