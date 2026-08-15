module Makoto
  class MonitorAppTest < TestCase
    setup do
      FileUtils.rm_f(Heartbeat.path)
      @proc_dir = File.join(Environment.dir, 'tmp/run/proc_monitor_test')
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

    def app(alive: true, pid: 4649, proc_dir: nil)
      health = Health.new(
        daemon: daemon(alive: alive, pid: pid),
        now: now,
        proc_dir: proc_dir || @proc_dir,
      )
      return MonitorApp.new(health: -> {health})
    end

    def get(app, path)
      status, headers, body = app.call({'PATH_INFO' => path})
      return {status: status, headers: headers, body: body.join}
    end

    # ハートビートを健全な状態にする。⚠ 経過を `now` の直前に置く。
    def healthy_heartbeat(jobs: 5)
      Heartbeat.touch(jobs: jobs, now: now - 1)
      return Heartbeat.stored
    end

    def fake_process(pid, command)
      dir = File.join(@proc_dir, pid.to_s)
      FileUtils.mkdir_p(dir)
      argv = command.is_a?(Array) ? command : command.split
      File.write(File.join(dir, 'cmdline'), "#{argv.join("\0")}\0\0\0")
      return dir
    end

    def test_healthz_returns_ok
      healthy_heartbeat
      response = get(app, '/healthz')

      assert_equal(200, response[:status])
      assert_equal("OK\n", response[:body])
      assert_equal('text/plain; charset=utf-8', response[:headers]['content-type'])
    end

    # ⚠⚠ **`/healthz` が実際に足すのはここ。**生死そのものは TCP の接続で分かるので、
    # **「生きているが仕事をしていない」を拾えることが口を生やす理由**（→ #15）。
    def test_healthz_reports_stale_heartbeat
      Heartbeat.touch(jobs: 5, now: now - (Heartbeat.limit * 2))
      response = get(app, '/healthz')

      assert_equal(503, response[:status])
      assert_include(response[:body], 'heartbeat is stale')
    end

    def test_healthz_reports_no_job
      Heartbeat.touch(jobs: 0, now: now - 1)
      response = get(app, '/healthz')

      assert_equal(503, response[:status])
      assert_include(response[:body], 'no posting job is registered')
    end

    def test_healthz_reports_dead_daemon
      healthy_heartbeat
      response = get(app(alive: false), '/healthz')

      assert_equal(503, response[:status])
      assert_include(response[:body], 'is not running')
    end

    # ⚠ 投稿の失敗は `/healthz` には出さない。**復旧を叩かせない側**なので分けてある。
    def test_healthz_ignores_posting_failure
      healthy_heartbeat
      Heartbeat.failure_limit.times {|i| Heartbeat.record_failure(slot: "slot-#{i}", now: now)}
      response = get(app, '/healthz')

      assert_equal(200, response[:status])
    end

    def test_posting_returns_ok_without_failure
      healthy_heartbeat
      response = get(app, '/healthz/posting')

      assert_equal(200, response[:status])
    end

    # ⚠⚠ **「一度も投稿していない」を赤にしない。**MAKOTO は 8/15〜10/31 の 2 か月半
    # 投稿しないので、⚠ ここを赤にすると 11/1 まで赤のままになる（→ Heartbeat）。
    def test_posting_stays_ok_while_never_posted
      healthy_heartbeat
      response = get(app, '/healthz/posting')

      assert_equal(200, response[:status])
      assert_nil(Heartbeat.posted_at)
    end

    def test_posting_reports_failure
      healthy_heartbeat
      Heartbeat.failure_limit.times {|i| Heartbeat.record_failure(slot: "slot-#{i}", now: now)}
      response = get(app, '/healthz/posting')

      assert_equal(503, response[:status])
      assert_include(response[:body], 'posting failed')
    end

    def test_orphans_returns_ok
      healthy_heartbeat
      fake_process(1234, 'sleep 300')
      response = get(app, '/healthz/orphans')

      assert_equal(200, response[:status])
    end

    def test_orphans_reports_orphan
      healthy_heartbeat
      fake_process(1234, ['bin/makoto_daemon.rb start'])
      response = get(app, '/healthz/orphans')

      assert_equal(503, response[:status])
      assert_include(response[:body], 'orphan process: 1234')
    end

    # ⚠⚠ **`/proc` が読めないときに「孤児は無い」と答えない**（→ #54）。
    def test_orphans_reports_unknown
      healthy_heartbeat
      response = get(app(proc_dir: File.join(@proc_dir, 'missing')), '/healthz/orphans')

      assert_equal(503, response[:status])
      assert_include(response[:body], 'cannot read /proc')
    end

    # 🔴 **口を 3 つに分けた理由そのもの。**⚠⚠ **投稿の警告は sticky**（消えるのは次に
    # 1 本投稿できたときだけ）なので、⚠ **孤児と同じ口に載せると、赤のまま残っている
    # 間に本物の孤児が埋もれる。**⚠ **片方が赤でももう片方が独立に動くこと**を見る。
    def test_posting_failure_does_not_mask_orphans
      healthy_heartbeat
      Heartbeat.failure_limit.times {|i| Heartbeat.record_failure(slot: "slot-#{i}", now: now)}

      assert_equal(503, get(app, '/healthz/posting')[:status])
      assert_equal(200, get(app, '/healthz/orphans')[:status])

      fake_process(1234, ['bin/makoto_daemon.rb start'])

      assert_equal(503, get(app, '/healthz/orphans')[:status])
      assert_include(get(app, '/healthz/orphans')[:body], 'orphan process: 1234')
    end

    def test_unknown_path_returns_not_found
      healthy_heartbeat

      assert_equal(404, get(app, '/')[:status])
      assert_equal(404, get(app, '/healthz/unknown')[:status])
      assert_equal(404, get(app, '/makoto')[:status])
    end

    # ⚠⚠ **判定できないことを「健全」と答えない。**⚠ **例外を 200 に倒すと、`Health`
    # が落ちている間だけ監視が緑になる**（設定の欠落・閾値の不正で実際に起きうる）。
    def test_error_falls_back_to_unhealthy
      broken = MonitorApp.new(health: -> {raise Ginseng::ConfigError, 'broken threshold'})
      response = get(broken, '/healthz')

      assert_equal(503, response[:status])
      assert_include(response[:body], 'broken threshold')
    end

    # ⚠ **リクエストごとに `Health` を作り直すこと。**⚠⚠ **1 つを使い回すと、痕跡が
    # 変わっても古い判定を返し続ける**（監視が「直ったこと」に気付けない）。
    def test_health_is_built_per_request
      healthy_heartbeat
      built = 0
      app = MonitorApp.new(health: lambda do
        built += 1
        next Health.new(daemon: daemon, now: now, proc_dir: @proc_dir)
      end)

      get(app, '/healthz')
      get(app, '/healthz')

      assert_equal(2, built)
    end
  end
end
