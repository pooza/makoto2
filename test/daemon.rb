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
  end
end
