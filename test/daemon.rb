require 'tmpdir'

module Makoto
  class DaemonTest < TestCase
    def setup
      @daemon = MakotoDaemon.new
    end

    # pid ファイルと `/proc` を差し替えた常駐。⚠ **番号は本物**（`Process.kill(0)` が
    # 通らないと `alive?` がそこで false になり、身元の判定まで届かない）。
    def with_daemon(command: nil, proc_dir: nil, pid: Process.pid)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'tmp/pids'))
        fake = proc_dir || File.join(dir, 'proc')
        if command
          entry = File.join(fake, pid.to_s)
          FileUtils.mkdir_p(entry)
          # ⚠ 実機は NUL 区切りで、末尾に詰め物が付く。
          File.write(File.join(entry, 'cmdline'), "#{Array(command).join("\0")}\0\0\0")
        end
        daemon = MakotoDaemon.new(working_dir: dir, proc_dir: fake)
        File.write(daemon.pid_file, pid.to_s) unless pid.nil?
        yield daemon
      end
    end

    def test_alive_without_a_pid_file
      with_daemon(pid: nil) do |daemon|
        assert_false(daemon.alive?)
      end
    end

    # ⚠ 本物の常駐は生きていると答える（**塞いだせいで検知できなくならないこと**）。
    def test_the_real_daemon_is_alive
      with_daemon(command: ['bin/makoto_daemon.rb start']) do |daemon|
        assert_true(daemon.alive?)
      end
    end

    # 🔴 **#80 の黄 6 の本体。**⚠⚠ **pid は再利用される。**⚠ `Process.kill(0, pid)` は
    # 「その番号が在るか」しか見ないので、**無関係なプロセスを常駐だと答えていた**
    # （実測 — `sleep 300` の pid を書くと `running (PID 354866)` と表示された）。
    def test_a_reused_pid_is_not_the_daemon
      with_daemon(command: ['sleep', '300']) do |daemon|
        assert_false(daemon.alive?)
      end
    end

    # ⚠⚠ **孤児の判定（#61）と同じ規則で見る。**⚠ argv にこの名前を含むだけの
    # 運用スクリプトを常駐と取り違えない（`bash -lc '… makoto_daemon.rb restart'`）。
    def test_a_wrapper_script_is_not_the_daemon
      with_daemon(command: ['bash', '-lc', 'bundle exec bin/makoto_daemon.rb restart']) do |daemon|
        assert_false(daemon.alive?)
      end
    end

    # ⚠⚠ **`status` は即座に終わるので常駐ではない**（#80 の緑 6）。⚠ pid ファイルが
    # そこを指しているなら、それは実体とずれている。
    def test_a_transient_subcommand_is_not_the_daemon
      with_daemon(command: ['bin/makoto_daemon.rb status']) do |daemon|
        assert_false(daemon.alive?)
      end
    end

    # ⚠ インタプリタ越しでも本物は本物（`ruby --yjit bin/makoto_daemon.rb start`）。
    def test_the_daemon_behind_interpreter_options_is_alive
      with_daemon(command: ['ruby', '--yjit', 'bin/makoto_daemon.rb', 'start']) do |daemon|
        assert_true(daemon.alive?)
      end
    end

    # ⚠⚠ **確かめられないときは「生きている」に倒す。**⚠ `/proc` の無い環境で
    # 「死んでいる」と答えると、**健全な常駐の横にもう 1 本立ち上がる。**
    def test_alive_falls_back_without_proc
      with_daemon(proc_dir: File.join(Dir.tmpdir, 'makoto-no-such-proc')) do |daemon|
        assert_true(daemon.alive?)
      end
    end

    # ⚠ **本物の `/proc` で見る。**⚠⚠ **テストプロセス自身の pid を書いても
    # 「動いている」と答えないこと**（差し替えた `/proc` だけで通る形にしない）。
    def test_a_foreign_pid_is_not_the_daemon_on_the_real_proc
      with_daemon(proc_dir: ProcessIdentity::PROC_DIR) do |daemon|
        assert_false(daemon.alive?)
      end
    end

    # 🔴 **痕跡が書けなくても常駐は止めない**（リリース前レビューの黄 1）。
    # ⚠⚠ **`Scheduler` 側の `record_tick` / `touch` と同じ扱い**にする — ⚠ **素で呼ぶと
    # `tmp/run` が書けないだけで `start` の rescue が再送出し、監視の口も投稿も
    # 立ち上がらないまま systemd が 5 秒ごとに叩き直す。**
    def test_a_broken_trace_does_not_stop_the_start
      # ⚠ **元のメソッドを持って戻す**（`class << self` の中に居るので
      # `remove_method` では復元ではなく削除になる → `test/scheduler.rb`）。
      original = Heartbeat.method(:record_start)
      Heartbeat.define_singleton_method(:record_start) {|**| raise 'boom'}

      assert_nothing_raised {@daemon.send(:record_start)}
    ensure
      Heartbeat.define_singleton_method(:record_start, original)
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
