module Makoto
  class HealthTest < TestCase
    setup do
      FileUtils.rm_f(Heartbeat.path)
      @proc_dir = File.join(Environment.dir, 'tmp/run/proc_test')
      FileUtils.rm_rf(@proc_dir)
      FileUtils.mkdir_p(@proc_dir)
    end

    teardown do
      FileUtils.rm_f(Heartbeat.path)
      FileUtils.rm_rf(@proc_dir)
    end

    def now
      return Time.new(2026, 11, 4, 12, 0, 0, '+09:00')
    end

    def daemon(alive: true, pid: 4649)
      stub = MakotoDaemon.new
      stub.define_singleton_method(:alive?) {alive}
      stub.define_singleton_method(:pid) {pid}
      return stub
    end

    def health(alive: true, pid: 4649)
      return Health.new(daemon: daemon(alive: alive, pid: pid), now: now, proc_dir: @proc_dir)
    end

    # `/proc/{pid}/cmdline` は NUL 区切り。
    def fake_process(pid, command)
      dir = File.join(@proc_dir, pid.to_s)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 'cmdline'), command.split.join("\0"))
      return dir
    end

    def with_file_read_error(path, error)
      read = File.method(:read)
      File.define_singleton_method(:read) do |target, *args|
        raise error if target == path
        read.call(target, *args)
      end
      yield
    ensure
      File.define_singleton_method(:read, read)
    end

    def with_file_ownership(path, owned)
      owned_method = File.method(:owned?)
      File.define_singleton_method(:owned?) do |target|
        target == path ? owned : owned_method.call(target)
      end
      yield
    ensure
      File.define_singleton_method(:owned?, owned_method)
    end

    def beat(jobs: 1, at: nil)
      return Heartbeat.touch(jobs: jobs, now: at || now)
    end

    def test_healthy
      beat

      assert_equal(Health::OK, health.code)
      assert_equal([], health.errors)
      assert_equal([], health.warnings)
    end

    def test_not_running
      beat

      assert_equal(Health::ERROR, health(alive: false).code)
      assert_true(health(alive: false).errors.any? {|m| m.include?('not running')})
    end

    # ⚠⚠ **これが今回の主題。**プロセスは生きているのに投稿を 1 本も持っていない状態
    # （2026-08-05〜08 に実際に 3 日間続いた）を、生死だけ見る監視は拾えない。
    def test_running_but_idle
      beat(jobs: 0)

      assert_equal(Health::ERROR, health.code)
      assert_true(health.errors.any? {|m| m.include?('no posting job')})
    end

    # ⚠ ハートビートが止まれば、プロセスが生きていても異常。
    def test_stale_heartbeat
      config['/scheduler/heartbeat/interval'] = '1m'
      beat(at: now - 300)

      assert_equal(Health::ERROR, health.code)
      assert_true(health.errors.any? {|m| m.include?('stale')})
    end

    # ⚠ 痕跡が無ければ「止まっている」＋「仕事を持っていない」の両方。
    def test_without_heartbeat
      assert_equal(Health::ERROR, health.code)
      assert_equal(2, health.errors.size)
    end

    def test_no_orphan
      beat
      fake_process(4649, 'ruby bin/makoto_daemon.rb start')
      fake_process(5000, 'nginx: worker process')

      assert_equal([], health.orphans)
      assert_equal(Health::OK, health.code)
    end

    # ⚠⚠ **pid ファイルに無い常駐は孤児。**旧実装が 11 日分撒いた件の再発検知。
    def test_orphan_is_a_warning
      beat
      fake_process(4649, 'ruby bin/makoto_daemon.rb start')
      fake_process(4650, 'ruby bin/makoto_daemon.rb start')

      assert_equal([4650], health.orphans)
      # ⚠ 警告であって異常ではない。再起動の瞬間に一時的に 2 本になりうるので、
      # ここで復旧を叩かせるとループになる。
      assert_equal(Health::WARNING, health.code)
      assert_equal([], health.errors)
    end

    # ⚠ CLI 自身（`bin/makoto status`）を孤児と数えない。
    def test_cli_is_not_an_orphan
      beat
      fake_process(4650, 'ruby bin/makoto status')

      assert_equal([], health.orphans)
    end

    # ⚠⚠ **`/proc` が読めないときに「孤児は無い」と嘘をつかない。**守っているつもりで
    # 無防備になるのを防ぐ。
    def test_unreadable_proc_is_reported
      beat
      subject = Health.new(daemon: daemon, now: now, proc_dir: File.join(@proc_dir, 'missing'))

      assert_nil(subject.orphans)
      assert_equal(Health::WARNING, subject.code)
      assert_true(subject.warnings.any? {|m| m.include?('/proc')})
    end

    # ⚠ 同じユーザーの関連プロセスが読めないなら、孤児の有無は確定できない。
    # 「孤児なし」ではなく確認不能として警告する。
    def test_permission_denied_proc_is_reported
      beat
      dir = fake_process(4650, 'ruby bin/makoto_daemon.rb start')
      subject = health

      with_file_read_error(File.join(dir, 'cmdline'), Errno::EACCES) do
        assert_equal(Health::WARNING, subject.code)
        assert_nil(subject.orphans)
        assert_equal(['cannot read /proc (orphan check skipped)'], subject.warnings)
      end
    end

    # ⚠ 未分類の読み取りエラーも status を crash させず、確認不能に落とす。
    def test_unexpected_proc_read_error_is_reported
      beat
      dir = fake_process(4650, 'ruby bin/makoto_daemon.rb start')
      subject = health

      with_file_read_error(File.join(dir, 'cmdline'), Errno::EIO) do
        assert_nil(subject.orphans)
        assert_equal(['cannot read /proc (orphan check skipped)'], subject.warnings)
        assert_equal(Health::WARNING, subject.code)
      end
    end

    # ⚠ `hidepid=1` で読めない他ユーザーのプロセスは MAKOTO の孤児ではない。
    # その存在だけで恒常的な警告にしない。
    def test_unrelated_unreadable_process_does_not_warn
      beat
      dir = fake_process(9999, 'postgres: writer')
      subject = health

      with_file_ownership(dir, false) do
        with_file_read_error(File.join(dir, 'cmdline'), Errno::EACCES) do
          assert_equal([], subject.orphans)
          assert_equal([], subject.warnings)
          assert_equal(Health::OK, subject.code)
        end
      end
    end

    # ⚠ 読めた孤児は、他ユーザーのプロセスが読めなくても捨てない。
    def test_readable_orphan_wins_over_unrelated_unreadable_process
      beat
      fake_process(4650, 'ruby bin/makoto_daemon.rb start')
      unrelated = fake_process(9999, 'postgres: writer')
      subject = health

      with_file_ownership(unrelated, false) do
        with_file_read_error(File.join(unrelated, 'cmdline'), Errno::EACCES) do
          assert_equal([4650], subject.orphans)
          assert_equal(['orphan process: 4650'], subject.warnings)
          assert_equal(Health::WARNING, subject.code)
        end
      end
    end

    # ⚠ 列挙後に消えたプロセスは正常な競合。他の孤児の検出を止めない。
    def test_disappeared_process_does_not_mask_other_orphan
      beat
      disappeared = fake_process(4650, 'ruby bin/makoto_daemon.rb start')
      fake_process(4651, 'ruby bin/makoto_daemon.rb start')
      FileUtils.rm_f(File.join(disappeared, 'cmdline'))

      assert_equal([4651], health.orphans)
      assert_equal(Health::WARNING, health.code)
      assert_equal(['orphan process: 4651'], health.warnings)
    end

    def test_enoent_disappearance_is_clean_none
      beat
      disappeared = fake_process(4650, 'ruby bin/makoto_daemon.rb start')
      FileUtils.rm_f(File.join(disappeared, 'cmdline'))
      subject = health

      assert_equal([], subject.orphans)
      assert_equal([], subject.warnings)
      assert_equal(Health::OK, subject.code)
    end

    # ⚠ `cmdline` を open した後の消失は `ESRCH` になることもある。
    def test_esrch_disappearance_does_not_mask_other_orphan
      beat
      disappeared = fake_process(4650, 'ruby bin/makoto_daemon.rb start')
      fake_process(4651, 'ruby bin/makoto_daemon.rb start')
      subject = health

      with_file_read_error(File.join(disappeared, 'cmdline'), Errno::ESRCH) do
        assert_equal([4651], subject.orphans)
        assert_equal(['orphan process: 4651'], subject.warnings)
        assert_equal(Health::WARNING, subject.code)
      end
    end

    def test_esrch_disappearance_is_clean_none
      beat
      disappeared = fake_process(4650, 'ruby bin/makoto_daemon.rb start')
      subject = health

      with_file_read_error(File.join(disappeared, 'cmdline'), Errno::ESRCH) do
        assert_equal([], subject.orphans)
        assert_equal([], subject.warnings)
        assert_equal(Health::OK, subject.code)
      end
    end

    # ⚠ 異常が警告より優先される（復旧が先）。
    def test_error_wins_over_warning
      beat(jobs: 0)
      fake_process(4650, 'ruby bin/makoto_daemon.rb start')

      assert_equal(Health::ERROR, health.code)
    end
  end
end
