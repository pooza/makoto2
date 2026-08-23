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

    # その項目の stat が拒まれるか。⚠ **`File.directory?` と違い、「無い」と
    # 「拒まれた」を分ける。**
    def stat_denied?(entry)
      File.stat(entry)
      return false
    rescue Errno::EACCES
      return true
    end

    def test_alive_without_a_pid_file
      with_daemon(pid: nil) do |daemon|
        assert_false(daemon.alive?)
      end
    end

    # 🔴 **空・壊れた pid ファイルは `pid = 0` になる**（`File.read(...).to_i`）。
    # ⚠⚠ **`0` は truthy で、`Process.kill(0, 0)` は自分のプロセスグループ宛てなので
    # 成功する**ため、⚠ **これを「動いている」と答えると `run_restart` が
    # `Process.kill('TERM', 0)` ＝ 呼び出し元のプロセスグループ全体に TERM を送る**
    # （リリース前レビューの黄 3）。
    def test_a_broken_pid_file_is_not_the_daemon
      ['', "\n", 'abc', '0'].each do |body|
        with_daemon(pid: nil) do |daemon|
          File.write(daemon.pid_file, body)

          assert_equal(0, daemon.pid, "pid file: #{body.inspect}")
          assert_false(daemon.alive?, "pid file: #{body.inspect}")
        end
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

    # ⚠ signal の送り先を差し替える。⚠⚠ **本物の `EPERM` を作ると他人のプロセスへ
    # signal を送ることになる**ので、継ぎ目（`MakotoDaemon#signal`）で止める。
    def with_signal(daemon, &)
      daemon.define_singleton_method(:signal, &)
      return daemon
    end

    # 🔴 **#111 の本体（1）。**⚠⚠ **`EPERM` は「居るが signal を送れない」＝生きている。**
    # ⚠ 上流 1.15.28 の `Ginseng::Daemon#alive?` は `EPERM` も false に倒すので、
    # 🔴 **他人の権限で走っている常駐が「死んでいる」と読まれ、二重に起動しうる。**
    def test_a_permission_error_means_alive
      with_daemon(command: ['bin/makoto_daemon.rb start']) do |daemon|
        with_signal(daemon) {|*| raise Errno::EPERM}

        assert_true(daemon.alive?)
      end
    end

    # ⚠ 居ないものは死んでいる（塞いだせいで検知できなくならないこと）。
    def test_no_such_process_means_dead
      with_daemon(command: ['bin/makoto_daemon.rb start']) do |daemon|
        with_signal(daemon) {|*| raise Errno::ESRCH}

        assert_false(daemon.alive?)
      end
    end

    # 🔴 **#111 の本体（2）。**⚠⚠ **上流は先に pid ファイルを消してから TERM を送り、
    # `EPERM` を拾っていない** — 🔴 **pid ファイルだけ消えてプロセスは生き残る
    # ＝ 孤児が確定する。**⚠ **旧実装が孤児を 11 日分撒いた形。**
    def test_run_stop_keeps_the_pid_file_when_it_cannot_signal
      with_daemon(command: ['bin/makoto_daemon.rb start']) do |daemon|
        with_signal(daemon) {|*| raise Errno::EPERM}

        assert_raise(SystemExit) {daemon.send(:run_stop)}
        assert_path_exist(daemon.pid_file)
      end
    end

    # ⚠ 送れたら消す（従来どおり）。**順序だけを入れ替えている。**
    def test_run_stop_removes_the_pid_file_after_terminating
      with_daemon(command: ['bin/makoto_daemon.rb start']) do |daemon|
        sent = []
        with_signal(daemon) {|target, value| sent.push([target, value])}
        daemon.send(:run_stop)

        assert_equal([[Process.pid, 'TERM']], sent)
        assert_path_not_exist(daemon.pid_file)
      end
    end

    # 🔴 **#162。**⚠⚠ **空・壊れた pid ファイルは `0` になり、`0` は truthy** なので
    # `unless (target = pid)` を素通りする。⚠ **そのまま送ると
    # `Process.kill('TERM', 0)` ＝ 呼び出し元のプロセスグループ全体に TERM。**
    def test_run_stop_does_not_signal_a_broken_pid_file
      ['', "\n", 'abc', '0'].each do |body|
        with_daemon(command: ['sleep', '300']) do |daemon|
          File.write(daemon.pid_file, body)
          sent = []
          with_signal(daemon) {|target, value| sent.push([target, value])}
          daemon.send(:run_stop)

          assert_equal([], sent, "pid file: #{body.inspect}")
          assert_path_not_exist(daemon.pid_file, "pid file: #{body.inspect}")
        end
      end
    end

    # 🔴 **#162。**⚠⚠ **`alive?` が false と答えている相手に TERM を送っていた** —
    # ⚠ **`run_restart` は `run_stop if alive?` なので守られていたが、
    # `bin/makoto_daemon.rb stop` を直に叩く経路が素通しだった。**
    def test_run_stop_does_not_signal_a_reused_pid
      with_daemon(command: ['sleep', '300']) do |daemon|
        sent = []
        with_signal(daemon) {|target, value| sent.push([target, value])}

        assert_false(daemon.alive?)
        # ⚠ `alive?` の在否確認（signal 0）は数えない。**見たいのは TERM だけ。**
        sent.clear
        daemon.send(:run_stop)

        assert_equal([], sent)
        assert_path_not_exist(daemon.pid_file)
      end
    end

    # 🔴 **#169（Codex の P1）。**⚠⚠ **`/proc` が無い環境では身元を確かめられない** —
    # ⚠ **`daemon_pid?` はそれを `true` に倒す**（`alive?` にとっては正しい）ので、
    # 🔴 **止める側がそのまま使うと、素性の分からない pid へ TERM を送る。**
    # ⚠ **pid ファイルは残す**（`EPERM` の枝と同じ。消すと孤児が確定する）。
    def test_run_stop_refuses_when_proc_is_unavailable
      with_daemon(proc_dir: '/nonexistent') do |daemon|
        sent = []
        with_signal(daemon) {|target, value| sent.push([target, value])}

        assert_raise(SystemExit) {daemon.send(:run_stop)}
        assert_equal([], sent)
        assert_path_exist(daemon.pid_file)
      end
    end

    # 🔴 **#169。**⚠ **読めない（`EACCES`）ときも同じ。**
    def test_run_stop_refuses_when_the_argv_cannot_be_read
      with_daemon(command: ['bin/makoto_daemon.rb start']) do |daemon|
        daemon.define_singleton_method(:argv) {|*| raise Errno::EACCES}
        sent = []
        with_signal(daemon) {|target, value| sent.push([target, value])}

        assert_raise(SystemExit) {daemon.send(:run_stop)}
        assert_equal([], sent)
        assert_path_exist(daemon.pid_file)
      end
    end

    # 🔴 **#169 の 2 巡目（Codex）。**⚠⚠ **`/proc` は読めるが `/proc/{pid}` の stat が
    # 拒まれる形**（親に検索権が無い）。⚠ **`File.directory?` はこれを「無い」と
    # 同じ false に畳む**ので、⚠⚠ **「確かめて、居ないと分かった」に化けて TERM が
    # 飛んでいた。**🔴 **拒まれたなら送らず、pid ファイルも残す。**
    def test_run_stop_refuses_when_the_proc_entry_cannot_be_stat
      Dir.mktmpdir do |proc_dir|
        entry = File.join(proc_dir, Process.pid.to_s)
        FileUtils.mkdir_p(entry)
        # ⚠ 検索権（`x`）だけを落とす → 親は読めるが子の stat が `EACCES`。
        File.chmod(0o600, proc_dir)
        begin
          # ⚠⚠ **root で走らせると権限が効かない**（stat が通ってしまう）ので、
          # **そのときは判定できない**。
          omit('stat が拒まれない（root か)') unless stat_denied?(entry)
          with_daemon(proc_dir: proc_dir) do |daemon|
            sent = []
            with_signal(daemon) {|target, value| sent.push([target, value])}

            assert_raise(SystemExit) {daemon.send(:run_stop)}
            assert_equal([], sent)
            assert_path_exist(daemon.pid_file)
          end
        ensure
          # ⚠ 戻さないと `Dir.mktmpdir` の後始末が失敗する。
          File.chmod(0o700, proc_dir)
        end
      end
    end

    # ⚠⚠ **「もう居ない」は確かめられている**（`/proc/{pid}` が無い）ので、
    # 🔴 **拒まずに掃除する。**⚠ **ここを拒むと `run_start` が「already running」で
    # 無言終了する**（#80 の黄 6）。
    def test_run_stop_still_cleans_up_when_the_process_is_gone_from_proc
      # ⚠ `/proc` そのものは在り、その中に pid の項目だけが無い形を作る。
      Dir.mktmpdir do |proc_dir|
        with_daemon(proc_dir: proc_dir) do |daemon|
          with_signal(daemon) {|*| raise Errno::ESRCH}
          daemon.send(:run_stop)

          assert_path_not_exist(daemon.pid_file)
        end
      end
    end

    # ⚠ 居ないなら掃除してよい。⚠⚠ **残すと `run_start` が「already running」で
    # 無言終了する**（#80 の黄 6 で踏んだ形）。
    def test_run_stop_removes_the_pid_file_when_the_process_is_gone
      with_daemon(command: ['bin/makoto_daemon.rb start']) do |daemon|
        with_signal(daemon) {|*| raise Errno::ESRCH}
        daemon.send(:run_stop)

        assert_path_not_exist(daemon.pid_file)
      end
    end

    # ⚠ 設定の検証を差し替える（`errors` は読み込んだファイルを見るので
    # `config['/x'] = y` では変わらない → test/config.rb）。
    def with_config_errors(found)
      config.define_singleton_method(:errors) {found}
      config.reload
      recorder = []
      @daemon.instance_variable_set(:@logger, Struct.new(:x) do
        define_method(:error) {|payload| recorder.push(payload)}
        define_method(:info) {|payload| payload}
      end.new(nil))
      yield
      return recorder
    ensure
      config.singleton_class.remove_method(:errors)
      config.reload
    end

    # 🔴 **#99。**⚠⚠ **通らなくても常駐は止めない**（2026-08-21・オーナー判断）。
    # ⚠ **止めると systemd の `Restart=always` が 5 秒ごとに叩き直す形**になり、
    # ⚠⚠ **11/4 当日に踏むと復旧の時間が要る。**代わりに `/healthz` を赤にする。
    def test_a_broken_config_is_logged_but_does_not_stop_the_start
      recorder = with_config_errors(['壊れています in schema abc']) do
        assert_nothing_raised {@daemon.send(:validate_config)}
      end

      assert_equal(1, recorder.size)
      assert_equal('invalid', recorder.first[:config])
      assert_equal(1, recorder.first[:count])
    end

    # ⚠ 通っていれば何も言わない（**平常時にログを汚さない**）。
    def test_a_valid_config_is_not_logged
      recorder = with_config_errors([]) do
        assert_empty(@daemon.send(:validate_config))
      end

      assert_empty(recorder)
    end

    # ⚠⚠ **検証そのものが落ちても常駐は上げる。**⚠ schema が読めないだけでボットが
    # 動かなくなるほうが痛い（`record_start` と同じ扱い）。
    def test_a_failed_validation_does_not_stop_the_start
      config.define_singleton_method(:validation_errors) {raise 'boom'}
      recorder = []
      @daemon.instance_variable_set(:@logger, Struct.new(:x) do
        define_method(:error) {|payload| recorder.push(payload)}
      end.new(nil))

      assert_nothing_raised {@daemon.send(:validate_config)}
      assert_equal('unverified', recorder.first[:config])
    ensure
      config.singleton_class.remove_method(:validation_errors)
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

    # ログを数えるための受け皿。⚠ **水準ごとに分けて数える**（#106 は失効とそれ以外を
    # 分けるのが要点なので、「何か出た」では足りない）。
    Recorder = Struct.new(:records) do
      [:info, :warn, :error].each do |severity|
        define_method(severity) {|payload| records[severity].push(payload)}
      end

      def debug(*)
      end
    end

    def records_of_verify
      records = Hash.new {|hash, key| hash[key] = []}
      @daemon.instance_variable_set(:@logger, Recorder.new(records))
      @daemon.send(:verify_credentials).join
      return records
    end

    # ⚠ **`return` に多行のチェインを繋がない**（4 スペースを要求される →
    # ginseng-style の docs/ruby.md）。受け皿の変数に置く。
    def stub_verify(status, body = {})
      headers = {'Content-Type' => 'application/json'}
      stub = stub_request(:get, "#{config['/mastodon/url']}/api/v1/accounts/verify_credentials")
      return stub.to_return(status: status, body: body.to_json, headers: headers)
    end

    # 🔴 **トークンが生きているかを起き上がりで 1 回見る**（#106）。
    # ⚠ **投稿はしない**ので、当日の並びには影響しない。
    def test_the_token_is_verified_at_start
      stub_verify(200, acct: 'test', statuses_count: 183)
      records = records_of_verify

      assert_equal(1, records[:info].size)
      assert_equal('test', records[:info].first[:acct])
      assert_empty(records[:error])
    end

    # 🔴 **失効はエラー。**⚠⚠ **これが無いと、気付くのが 11/3 になる。**
    def test_a_dead_token_is_logged_as_an_error
      stub_verify(401, error: 'The access token is invalid')
      records = records_of_verify

      assert_equal(1, records[:error].size)
      assert_equal('token is not valid', records[:error].first[:message])
      assert_empty(records[:warn])
    end

    # ⚠⚠ **「引けなかった」を「失効」に化けさせない**（→ #124 と同じ形）。
    # ⚠ Mastodon 側の不調は警告どまり。
    def test_an_unreachable_mastodon_is_only_a_warning
      stub_verify(404)
      records = records_of_verify

      assert_equal(1, records[:warn].size)
      assert_equal('could not verify the token', records[:warn].first[:message])
      assert_empty(records[:error])
    end

    # ⚠ **失敗しても常駐は止めない**（痕跡が書けないときと同じ扱い）。
    def test_a_failed_verification_does_not_raise
      stub_verify(401)

      assert_nothing_raised {@daemon.send(:verify_credentials).join}
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
