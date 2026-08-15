module Makoto
  class HeartbeatTest < TestCase
    setup do
      clear
    end

    teardown do
      clear
    end

    # ⚠ 差し替え用の一時ファイルと鍵も片付ける（→ `Heartbeat#write` / `#with_lock`）。
    def clear
      FileUtils.rm_f(Heartbeat.path)
      FileUtils.rm_f(Heartbeat.lock_path)
      FileUtils.rm_f(Dir.glob("#{Heartbeat.path}.*.tmp"))
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
      Heartbeat.record_failure(now: now)
      Heartbeat.record_failure(now: now + 60)

      assert_equal(2, Heartbeat.failures)
      assert_equal(now + 60, Heartbeat.failed_at)
      assert_nil(Heartbeat.posted_at)

      Heartbeat.record_success(now: now + 120)

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
      Heartbeat.record_failure(now: now)
      Heartbeat.touch(jobs: 5, now: now + 60)

      assert_equal(1, Heartbeat.failures)
      assert_equal(now, Heartbeat.failed_at)
      assert_equal(5, Heartbeat.jobs)
    end

    # ⚠ **逆向きも。**枠の結末がハートビートの側を消さないこと。
    def test_record_keeps_the_heartbeat
      Heartbeat.touch(jobs: 5, now: now)
      Heartbeat.record_success(now: now + 60)

      assert_equal(5, Heartbeat.jobs)
      assert_equal(now.getutc.iso8601, Heartbeat.read[:at])
    end

    # ⚠⚠ **時刻の欠けた痕跡でも、投稿の結末は引き継ぐ。**`read` は nil を返すが、
    # 書き直す側は `stored` を見るため。
    def test_update_keeps_the_record_without_time
      FileUtils.mkdir_p(File.dirname(Heartbeat.path))
      File.write(Heartbeat.path, {failures: 2}.to_json)
      Heartbeat.record_failure(now: now)

      assert_nil(Heartbeat.read)
      assert_equal(3, Heartbeat.failures)
    end

    # ⚠⚠ **同じ枠は 1 回しか数えない**（#81）。⚠ **時刻だけは進める**（最後に落ちた
    # のがいつかは知りたい）。
    def test_the_same_slot_is_counted_once
      Heartbeat.record_failure(slot: 'live-1', now: now)
      Heartbeat.record_failure(slot: 'live-1', now: now + 5)

      assert_equal(1, Heartbeat.failures)
      assert_equal(now + 5, Heartbeat.failed_at)

      Heartbeat.record_failure(slot: 'live-2', now: now + 180)

      assert_equal(2, Heartbeat.failures)
    end

    # ⚠ **1 本出れば覚えている枠も忘れる。**忘れないと、次に同じ枠が落ちても
    # 数えられない（枠の識別子は日付を含むので実際には重ならないが、ここは対称に）。
    def test_a_success_forgets_the_counted_slots
      Heartbeat.record_failure(slot: 'live-1', now: now)
      Heartbeat.record_success(now: now + 60)
      Heartbeat.record_failure(slot: 'live-1', now: now + 120)

      assert_equal(1, Heartbeat.failures)
    end

    # ⚠⚠ **覚える枠の数は上限つき。**痕跡を無限に太らせない（ライブ当日は 160 枠）。
    def test_counted_slots_are_bounded
      (Heartbeat::COUNTED_SLOTS + 10).times {|i| Heartbeat.record_failure(slot: "live-#{i}", now: now)}

      assert_equal(Heartbeat::COUNTED_SLOTS + 10, Heartbeat.failures)
      assert_equal(Heartbeat::COUNTED_SLOTS, Heartbeat.stored[:slots].size)
    end

    # ⚠⚠ **書き込み中の痕跡を読ませない**（#81 のレビュー指摘）。`File.write` は
    # **切り詰めてから書く**ので、⚠ **その隙に読んだ側は壊れた JSON を掴む。**
    #
    # 🔴 **これは「監視のせいで監視が誤報する」形。**読めない痕跡は `stale?` が true に
    # なり、⚠⚠ **`makoto status` が 1（復旧させる）を返して monit が正常な常駐を
    # 再起動する。**⚠ **投稿ごとに書くようになって窓が広がった**（実測で 2,000 回中
    # 625 回が nil だった）。
    def test_read_never_sees_a_partial_write
      Heartbeat.touch(jobs: 5, now: now)
      results = []
      reader = Thread.new {500.times {results.push(Heartbeat.read)}}
      500.times {|i| Heartbeat.record_failure(slot: "live-#{i}", now: now)}
      reader.join

      assert_equal([], results.select(&:nil?))
    end

    # ⚠ 差し替えに使った一時ファイルを残さない。
    def test_write_leaves_no_temporary_file
      Heartbeat.touch(jobs: 5, now: now)

      assert_equal([], Dir.glob("#{Heartbeat.path}.*.tmp"))
    end

    # ⚠⚠ **`Mutex` はプロセス内のスレッドしか守らない**（#81 のレビュー指摘）。
    # ⚠ **常駐は再起動で一時的に 2 本になりうる** — `Health` が孤児で復旧を叩かせない
    # のはまさにそれが起きるからで、**同じ前提をここでも置く。**
    # ⚠ **実測では 600 のはずが 142 しか数えられなかった。**
    def test_update_is_serialized_across_processes
      rounds = 100
      Heartbeat.touch(jobs: 5, now: now)
      # ⚠ **書き込み可能な SQLite の接続を持ったまま fork しない**（sqlite3 が警告を
      # 出す。⚠⚠ **子の中で閉じても遅い** — 警告は fork の時点で出る）。
      # ⚠ **他のテストが開いたものも含めて手放す** — この試験は痕跡のファイルしか
      # 触らない。Sequel は次に使うときに繋ぎ直す。
      Sequel::DATABASES.each(&:disconnect)
      pid = fork do
        rounds.times {|i| Heartbeat.record_failure(slot: "child-#{i}", now: now)}
        # ⚠ `exit!` にする。テストの teardown を子で走らせない。
        exit!(0)
      end
      rounds.times {|i| Heartbeat.record_failure(slot: "parent-#{i}", now: now)}
      Process.waitpid(pid)

      assert_equal(rounds * 2, Heartbeat.failures)
    end

    def test_failing
      config['/scheduler/posting/failure_limit'] = 3
      2.times {Heartbeat.record_failure(now: now)}

      assert_false(Heartbeat.failing?)

      Heartbeat.record_failure(now: now)

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
