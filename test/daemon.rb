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
    # ⚠ 中身は Announcement / Live 側のテストが見る。ここは**並んでいること**だけ。
    def test_register_jobs
      Scheduler.instance.clear

      @daemon.register_jobs

      # 予告（#14）1 本 ＋ ライブ（#13）4 本。
      assert_equal(5, Scheduler.instance.send(:jobs))
    ensure
      Scheduler.instance.clear
    end

    # ⚠ 冪等キーの前半になる名前が衝突しないこと。⚠⚠ **同じ名前が 2 本あると、同じ
    # 枠の時刻で同じキーになり、片方の投稿が Mastodon 側で畳まれて消える。**
    def test_job_names_are_unique
      Scheduler.instance.clear

      @daemon.register_jobs
      names = Scheduler.instance.instance_variable_get(:@jobs).map(&:name)

      assert_equal(names.uniq, names)
    ensure
      Scheduler.instance.clear
    end
  end
end
