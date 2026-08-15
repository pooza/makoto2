module Makoto
  class HeartbeatTest < TestCase
    setup do
      FileUtils.rm_f(Heartbeat.path)
    end

    teardown do
      FileUtils.rm_f(Heartbeat.path)
    end

    def now
      return Time.new(2026, 11, 4, 12, 0, 0, '+09:00')
    end

    # ⚠ **テストは稼働中の痕跡を書き換えない**（`Environment.db` と同じ理由）。
    def test_path_is_separated_in_test
      assert_equal(File.join(Environment.dir, 'tmp/run/heartbeat_test.json'), Heartbeat.path)
    end

    def test_touch_and_read
      Heartbeat.touch(jobs: 3, now: now)
      record = Heartbeat.read

      assert_equal(3, record[:jobs])
      assert_equal(Package.version, record[:version])
      assert_equal(Process.pid, record[:pid])
      assert_equal(now.getutc.iso8601, record[:at])
    end

    def test_read_without_file
      assert_nil(Heartbeat.read)
      assert_nil(Heartbeat.jobs)
      assert_nil(Heartbeat.age)
    end

    # ⚠⚠ **壊れていたら nil。**中身を信じて「健全」と誤答しない。
    def test_read_broken_file
      FileUtils.mkdir_p(File.dirname(Heartbeat.path))
      File.write(Heartbeat.path, 'not json')

      assert_nil(Heartbeat.read)
      assert_true(Heartbeat.stale?)
    end

    # ⚠ 時刻の欠けた痕跡も読めないものとして扱う（経過が出せない）。
    def test_read_file_without_time
      FileUtils.mkdir_p(File.dirname(Heartbeat.path))
      File.write(Heartbeat.path, {jobs: 1}.to_json)

      assert_nil(Heartbeat.read)
    end

    def test_age
      Heartbeat.touch(jobs: 1, now: now)

      assert_equal(90, Heartbeat.age(now + 90).round)
    end

    # ⚠⚠ **閾値は設定から出す。**間隔を延ばした瞬間に監視が誤検知しないこと。
    def test_limit_comes_from_config
      config['/scheduler/heartbeat/interval'] = '10m'

      assert_equal(600 * Heartbeat::STALE_FACTOR, Heartbeat.limit)
    end

    def test_stale
      config['/scheduler/heartbeat/interval'] = '1m'
      Heartbeat.touch(jobs: 1, now: now)

      # ⚠ 1 回の取りこぼしでは騒がない。
      assert_false(Heartbeat.stale?(now + 120))
      assert_true(Heartbeat.stale?(now + 181))
    end

    # ⚠ **痕跡が無ければ「止まっている」。**
    def test_stale_without_file
      assert_true(Heartbeat.stale?(now))
    end

    def test_rejects_bad_interval
      config['/scheduler/heartbeat/interval'] = 'soon'

      assert_raise(Ginseng::ConfigError) {Heartbeat.limit}
    end

    # ⚠⚠ **ここから #78。**投稿の結末を数える。

    def test_record_success_and_failure
      Heartbeat.record_failure(now)
      Heartbeat.record_failure(now + 60)

      assert_equal(2, Heartbeat.failures)
      assert_equal(now + 60, Heartbeat.failed_at)
      assert_nil(Heartbeat.posted_at)

      Heartbeat.record_success(now + 120)

      assert_equal(0, Heartbeat.failures)
      assert_equal(now + 120, Heartbeat.posted_at)
    end

    def test_failures_without_file
      assert_equal(0, Heartbeat.failures)
      assert_nil(Heartbeat.posted_at)
      assert_nil(Heartbeat.failed_at)
    end

    # ⚠⚠ **ハートビートは 1 時間ごとに書き直される。**素に書き直すと**枠の結末が
    # 毎時ぜんぶ消える。**
    def test_touch_keeps_the_posting_record
      Heartbeat.record_failure(now)
      Heartbeat.touch(jobs: 5, now: now + 60)

      assert_equal(1, Heartbeat.failures)
      assert_equal(now, Heartbeat.failed_at)
      assert_equal(5, Heartbeat.jobs)
    end

    # ⚠ **逆向きも。**枠の結末がハートビートの側を消さないこと。
    def test_record_keeps_the_heartbeat
      Heartbeat.touch(jobs: 5, now: now)
      Heartbeat.record_success(now + 60)

      assert_equal(5, Heartbeat.jobs)
      assert_equal(now.getutc.iso8601, Heartbeat.read[:at])
    end

    # ⚠⚠ **時刻の欠けた痕跡でも、投稿の結末は引き継ぐ。**`read` は nil を返すが、
    # 書き直す側は `stored` を見るため。
    def test_update_keeps_the_record_without_time
      FileUtils.mkdir_p(File.dirname(Heartbeat.path))
      File.write(Heartbeat.path, {failures: 2}.to_json)
      Heartbeat.record_failure(now)

      assert_nil(Heartbeat.read)
      assert_equal(3, Heartbeat.failures)
    end

    def test_failing
      config['/scheduler/posting/failure_limit'] = 3
      2.times {Heartbeat.record_failure(now)}

      assert_false(Heartbeat.failing?)

      Heartbeat.record_failure(now)

      assert_true(Heartbeat.failing?)
    end

    # ⚠⚠ **閾値は設定から出す**（`limit` と同じ理由）。⚠ **既定値に逃がさない** —
    # 設定を消しただけで検知が静かに緩む形を作らない（#77 の裏返し）。
    def test_rejects_bad_failure_limit
      config['/scheduler/posting/failure_limit'] = 0

      assert_raise(Ginseng::ConfigError) {Heartbeat.failure_limit}

      config['/scheduler/posting/failure_limit'] = 'many'

      assert_raise(Ginseng::ConfigError) {Heartbeat.failure_limit}
    end
  end
end
