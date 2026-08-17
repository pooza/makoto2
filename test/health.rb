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
    #
    # ⚠⚠ **配列を渡せば argv の区切りをそのまま書ける。**文字列を渡すと空白で割るが、
    # ⚠ **実機の常駐は `bin/makoto_daemon.rb start` が 1 要素**なので、その形を
    # 表現できないと #61 の回帰テストが本物を模せない。
    def fake_process(pid, command)
      dir = File.join(@proc_dir, pid.to_s)
      FileUtils.mkdir_p(dir)
      argv = command.is_a?(Array) ? command : command.split
      # ⚠ 実機は末尾に NUL の詰め物が付く。空要素を落とせているかもここで見る。
      File.write(File.join(dir, 'cmdline'), "#{argv.join("\0")}\0\0\0")
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

    # ⚠⚠ **健全な常駐は「ハートビート」と「tick」の両方の痕跡を残す**（#80 の黄 7）。
    # ⚠ **ここで tick まで書くのは、健全の定義がそうなったから** — 片方だけの痕跡は
    # まさに検知したい状態（tick 側だけが詰まった常駐）を指す。
    def beat(jobs: 1, at: nil, tick: true)
      Heartbeat.record_tick(now: at || now) if tick
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

    # 🔴 **#80 の黄 7 の本体。**⚠⚠ **ハートビートは tick とは別の rufus ジョブ**なので、
    # ⚠ **tick 側だけが詰まってもハートビートは動き続ける** — **「生きているが仕事を
    # していない」を見るための痕跡が、まさにその状態で健全を返していた。**
    def test_stale_tick_with_a_live_heartbeat
      beat(tick: false)
      Heartbeat.record_tick(now: now - (Heartbeat.tick_limit * 2))

      assert_equal(Health::ERROR, health.code)
      assert_true(health.errors.any? {|m| m.include?('tick is stale')})
      # ⚠ ハートビートそのものは新しいままであること（＝旧実装が緑を返した状況）。
      assert_not_include(health.errors, 'heartbeat is stale')
    end

    # ⚠ 猶予の内側なら鳴らない。⚠⚠ **1 回の tick は投稿の再送で 90 秒以上かかりうる**
    # ので、tick の間隔（10 秒）を基準にすると誤報する。
    def test_a_slow_tick_is_not_stale
      beat(tick: false)
      Heartbeat.record_tick(now: now - (Heartbeat.tick_limit - 1))

      assert_equal(Health::OK, health.code)
    end

    # ⚠⚠ **痕跡が無いのは「一度も回っていない」。**⚠ 常駐は登録の直後に 1 回叩く
    # （→ `Scheduler#schedule_posts`）ので、生きているのに無いのは異常。
    def test_a_missing_tick_is_stale
      beat(tick: false)

      assert_true(health.errors.any? {|m| m.include?('tick is stale')})
    end

    # ⚠ 閾値は設定から出す（間隔を延ばした瞬間に誤検知しはじめるのを防ぐ）。
    def test_tick_threshold_comes_from_the_setting
      config['/scheduler/tick_stale'] = '1h'
      beat(tick: false)
      Heartbeat.record_tick(now: now - 600)

      assert_equal(Health::OK, health.code)
    end

    # ⚠⚠ **既定値に逃がさない**（#77 の裏返し）。設定を消しただけで検知が静かに
    # 消える形にしない。
    def test_a_broken_tick_threshold_raises
      config['/scheduler/tick_stale'] = 'いつか'
      beat

      assert_raise(Ginseng::ConfigError) {health.errors}
    end

    # ⚠ 痕跡が無ければ「ハートビートが止まっている」＋「tick が回っていない」＋
    # 「仕事を持っていない」の 3 つ。
    def test_without_heartbeat
      assert_equal(Health::ERROR, health.code)
      assert_equal(3, health.errors.size)
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

    # ⚠⚠ **argv に文字列を含むだけの無関係なプロセスを孤児と報告しない**（#61）。
    # ⚠ **踏みやすいのは運用側の経路** — 復旧のラッパースクリプト・デプロイのシェル・
    # `pgrep` のワンライナー。**恒常的に踏むと本物の孤児が誤報に埋もれる。**
    def test_unrelated_process_is_not_an_orphan
      beat
      fake_process(4650, 'sleep 60 makoto_daemon_dummy')
      fake_process(4651, ['bash', '-lc', 'bundle exec bin/makoto_daemon.rb restart'])
      fake_process(4652, ['/usr/local/bin/makoto_daemon-restart'])
      fake_process(4653, ['pgrep', '-af', 'makoto_daemon'])

      assert_equal([], health.orphans)
      assert_equal(Health::OK, health.code)
    end

    # ⚠⚠ **これと上の 2 つが揃って初めて #61 の回帰テストになる。片方だけでは通る。**
    #
    # ⚠ **実機（bydo・2026-08-15 実測）の常駐は argv が 1 要素**で、
    # `bin/makoto_daemon.rb start` がまるごと入っている（bundler 経由の起動で `$0` が
    # 書き換わるため）。**要素をそのまま突き合わせる実装だとここで取り逃がす。**
    def test_real_daemon_argv_is_a_single_element
      beat
      fake_process(4650, ['bin/makoto_daemon.rb start'])

      assert_equal([4650], health.orphans)
      assert_equal(Health::WARNING, health.code)
    end

    # ⚠ インタプリタ経由（`ruby bin/makoto_daemon.rb start`）でも検知する。
    def test_daemon_behind_an_interpreter_is_an_orphan
      beat
      fake_process(4650, '/home/deploy/.rbenv/versions/4.0.6/bin/ruby bin/makoto_daemon.rb restart')

      assert_equal([4650], health.orphans)
    end

    # ⚠⚠ **インタプリタのオプションを読み飛ばす**（#68 のレビュー指摘）。
    # ⚠ **スクリプトの位置を「インタプリタの次」と決め打つと、`--yjit` を付けた
    # 起動を取り逃がす。**bydo の Ruby は YJIT 有効なので、実際に取りうる形。
    def test_daemon_behind_interpreter_options_is_an_orphan
      beat
      fake_process(4650, 'ruby --yjit bin/makoto_daemon.rb start')
      fake_process(4651, ['ruby', '-W0', '-Ilib', '/srv/makoto2/bin/makoto_daemon.rb', 'start'])

      assert_equal([4650, 4651], health.orphans)
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

    # ⚠⚠ **ここから #78。**「登録は 5 本あるのに 1 本も出ない」を拾う。

    # ⚠ **これが #78 の再現。**⚠⚠ **これまでは 160 枠が全滅しても 0（健全）だった。**
    def test_consecutive_posting_failures_are_a_warning
      config['/scheduler/posting/failure_limit'] = 3
      beat
      3.times {Heartbeat.record_failure(now: now)}

      assert_equal(Health::WARNING, health.code)
      assert_true(health.warnings.any? {|m| m.include?('posting failed 3 times')})
      # ⚠⚠ **異常（1）にはしない。**再起動しても直らないので、検知 → 再起動 →
      # また失敗のループになる（→ Health の冒頭）。
      assert_equal([], health.errors)
    end

    # ⚠ **閾値の手前では鳴らさない。**Mastodon 側の一時的な失敗で毎回鳴らない。
    def test_a_few_failures_are_not_a_warning
      config['/scheduler/posting/failure_limit'] = 3
      beat
      2.times {Heartbeat.record_failure(now: now)}

      assert_equal(Health::OK, health.code)
    end

    # ⚠⚠ **原稿が無いだけの日を警告にしない。**MAKOTO は 8/15〜10/31 の 2 か月半、
    # **枠はあるのに 1 本も投稿しない**（本文の無い枠は数に入らない）。
    def test_never_posted_is_not_a_warning
      beat

      assert_nil(health.posted_at)
      assert_equal(0, health.posting_failures)
      assert_equal(Health::OK, health.code)
    end

    # ⚠ **1 本出れば消える。**時間では薄れない（→ Health の冒頭）。
    def test_a_success_clears_the_warning
      config['/scheduler/posting/failure_limit'] = 3
      beat
      3.times {Heartbeat.record_failure(now: now)}

      assert_equal(Health::WARNING, health.code)

      Heartbeat.record_success(now: now)

      assert_equal(Health::OK, health.code)
      assert_equal(now, health.posted_at)
    end

    # ⚠ 死んでいるときは `errors` の側が言う。同じことを 2 度書かない。
    def test_dead_daemon_does_not_add_the_posting_warning
      config['/scheduler/posting/failure_limit'] = 1
      beat
      Heartbeat.record_failure(now: now)

      assert_equal([], health(alive: false).warnings)
    end

    # ⚠ 孤児と重なったら両方出す（原因が別なので、片方に隠されると調べ損ねる）。
    def test_posting_warning_and_orphan_are_both_reported
      config['/scheduler/posting/failure_limit'] = 1
      beat
      Heartbeat.record_failure(now: now)
      fake_process(4650, 'ruby bin/makoto_daemon.rb start')

      assert_equal(2, health.warnings.size)
      assert_equal(Health::WARNING, health.code)
    end
  end
end
