module Makoto
  # ⚠⚠ **`makoto status` は当日に人が見る唯一の画面**（→ docs/CLAUDE.md「死活監視は
  # 『生きているか』と『仕事をしているか』を分ける」）。
  #
  # 🔴 **`Health#ticked_at` は `errors` が見ているのに、この画面が見せていなかった**
  # （#150 ＝ #107 の黄 C1）。⚠ **判定と表示が食い違うと、赤の理由が画面から読めない。**
  class MainCommandTest < TestCase
    setup do
      clear
    end

    teardown do
      clear
    end

    def clear
      FileUtils.rm_f(Heartbeat.path)
      FileUtils.rm_f(Heartbeat.lock_path)
      FileUtils.rm_f(Dir.glob("#{Heartbeat.path}.*.tmp"))
    end

    def now
      return Time.new(2026, 11, 4, 12, 0, 0, '+09:00')
    end

    def command
      return MainCommand.new
    end

    def daemon(alive: true, pid: 4649)
      stub = MakotoDaemon.new
      stub.define_singleton_method(:alive?) {alive}
      stub.define_singleton_method(:pid) {pid}
      return stub
    end

    def health(alive: true, pid: 4649)
      return Health.new(daemon: daemon(alive: alive, pid: pid), now: now)
    end

    def capture
      original = $stdout
      $stdout = StringIO.new
      yield
      return $stdout.string
    ensure
      $stdout = original
    end

    # ⚠ **`status` は終了コードで答えるので `exit` する。**画面のほうを見たいので、
    # ここでは終了そのものは捨てる。
    def status_output(alive: true, pid: 4649)
      stub = health(alive: alive, pid: pid)
      new_method = Health.method(:new)
      Health.define_singleton_method(:new) {|*, **| stub}
      return capture do
        command.status
      rescue SystemExit
        next
      end
    ensure
      Health.define_singleton_method(:new, new_method)
    end

    def test_tick_line_is_printed
      Heartbeat.record_tick(now: now - 30)
      Heartbeat.touch(jobs: 1, now: now)

      assert_match(/^tick: 30s ago \(limit \d+s\)$/, status_output)
    end

    # ⚠⚠ **死んでいれば 1 行だけ**（→ `status`）。tick の行を足しても増やさない。
    def test_a_dead_daemon_prints_one_line
      assert_equal("not running\n", status_output(alive: false))
    end

    # ⚠ **画面に出る 6 つが揃っていること**（docs の「見るのは 6 つ」）。
    def test_all_six_lines_are_printed
      Heartbeat.record_tick(now: now)
      Heartbeat.touch(jobs: 1, now: now)
      output = status_output

      ['running (PID ', 'jobs: ', 'heartbeat: ', 'tick: ', 'posting: ', 'orphans: ', 'sentry: '].each do |line|
        assert_include(output, line)
      end
    end

    # 🔴 **動いているリビジョンと枠の名前が画面に出る**（#242）。⚠ **行は増やさない。**
    def test_status_shows_the_revision_and_the_job_names
      Heartbeat.record_tick(now: now)
      Heartbeat.touch(jobs: 2, job_names: ['morning', 'song'], now: now)
      # ⚠ **痕跡を書いたのはこのプロセス**なので、pid ファイルの番号もそれに合わせる。
      output = status_output(pid: Process.pid)

      assert_match(/^running \(PID \d+, revision #{Regexp.escape(Package.revision.to_s)}\)$/, output)
      assert_include(output, "jobs: 2 (morning, song)\n")
    end

    # 🔴 **別のプロセスが書いた痕跡のリビジョンは出さない**（#242・Codex の P2）。
    # ⚠⚠ **再起動の直後・孤児がまだ書いているとき** — **新しい PID と古い revision を並べない。**
    def test_status_hides_a_revision_from_another_process
      Heartbeat.record_tick(now: now)
      Heartbeat.touch(jobs: 2, job_names: ['morning', 'song'], now: now)
      output = status_output(pid: Process.pid + 1)

      assert_include(output, "running (PID #{Process.pid + 1}, revision (heartbeat from PID #{Process.pid}))\n")
      assert_include(output, "jobs: 2 (heartbeat from PID #{Process.pid})\n")
    end

    # ⚠ **#242 より前の常駐（自分の痕跡だがリビジョンが無い）は `(unknown)`**（#354）。
    def test_status_with_an_own_heartbeat_without_a_revision
      Heartbeat.record_tick(now: now)
      Heartbeat.touch(jobs: 1, now: now)
      Heartbeat.update {|record| record.merge(revision: nil)}
      output = status_output(pid: Process.pid)

      assert_include(output, "running (PID #{Process.pid}, revision (unknown))\n")
      assert_include(output, "jobs: 1\n")
    end

    # 🔴 **Sentry の行は常駐が痕跡に書いた状態**（#347・Codex の P1）。⚠⚠ **CLI 自身の初期化では言わない。**
    def test_status_shows_the_sentry_state_of_the_daemon
      Heartbeat.record_tick(now: now)
      Heartbeat.touch(jobs: 1, now: now)
      Heartbeat.update {|record| record.merge(sentry: 'misconfigured')}

      assert_include(status_output(pid: Process.pid), 'sentry: 🔴 misconfigured')
      assert_include(status_output(pid: Process.pid + 1), "sentry: (heartbeat from PID #{Process.pid})\n")
    end

    # ⚠ **痕跡に書くのは書いたプロセスの状態**（テストは DSN を持たない）。
    def test_the_heartbeat_records_the_sentry_state
      Heartbeat.touch(jobs: 1, now: now)

      assert_equal('off', Heartbeat.read[:sentry])
    end

    # ⚠ **#242 より前の常駐が書いた痕跡でも落ちない**（本数だけ出す）。
    def test_status_without_job_names
      Heartbeat.record_tick(now: now)
      Heartbeat.touch(jobs: 1, now: now)

      assert_include(status_output(pid: Process.pid), "jobs: 1\n")
    end

    # 🔴 **騙した日付を画面の先頭で言う**（#174）。⚠⚠ **`systemctl restart` の 1 手が
    # 当日通しを始める**ので、⚠ **人が最初に叩くこのコマンドで言う。**
    def test_the_time_travel_is_printed_first
      with_time_travel {Heartbeat.touch(jobs: 1, now: now)}

      assert_match(%r{\A🔴 time travel: from 2026-11-04T11:58:00\+09:00 / scale 10 /}, status_output)
    end

    # ⚠ **撤収すれば消える。**🔴 **平常時の画面を変えない**（#154 の完了条件）。
    def test_no_time_travel_line_in_real_time
      Heartbeat.touch(jobs: 1, now: now)

      assert_not_include(status_output, 'time travel')
    end

    # 🔴 **CLI 自身が騙している場合は別に言う**（#154）。⚠⚠ **向きが逆で、経過が
    # 大きく出る** — ⚠ **常駐が実時間に居るのに `heartbeat is stale` の偽の赤になる。**
    def test_the_cli_says_when_it_is_the_one_faking_the_date
      Heartbeat.touch(jobs: 1, now: now)
      output = with_time_travel {status_output}

      assert_include(output, '🔴 time travel (this CLI): from 2026-11-04T11:58:00+09:00')
    end

    # 🔴 **負の経過を数字で出さない**（#154）。⚠⚠ **騙した時刻の原点はプロセスごと**
    # なので、⚠ **あとから起動した CLI は常に常駐より過去に居る。**
    def test_a_trace_from_the_future_is_not_printed_as_a_negative_number
      Heartbeat.record_start(now: now)
      Heartbeat.record_tick(now: now + 6_360_337)

      line = command.send(:format_tick, health)

      assert_not_match(/-\d/, line)
      assert_match(/\Aahead of this process \(limit \d+s\)\z/, line)
    end

    # ⚠ **ハートビートの側も同じ**（`format_age` — #150 より前から同じ引き算だった）。
    def test_a_heartbeat_from_the_future_is_not_printed_as_a_negative_number
      Heartbeat.touch(jobs: 1, now: now + 6_360_337)
      line = command.send(:format_age, health.heartbeat_age)

      assert_not_match(/-\d/, line)
      assert_match(/\Aahead of this process \(limit \d+s\)\z/, line)
    end

    def test_tick_with_a_trace
      Heartbeat.record_start(now: now - 120)
      Heartbeat.record_tick(now: now - 90)

      assert_match(/\A90s ago \(limit \d+s\)\z/, command.send(:format_tick, health))
    end

    # 🔴 **画面と判定を食い違わせない**（Codex の指摘・PR #153）。
    #
    # ⚠⚠ **一度 tick が完走してから再起動すると、`record_start` は古い `ticked_at` を
    # 残したまま新しい `started_at` を書く。**⚠ **`tick_stale?` は新しいほう（＝ 起動）を
    # 見て緑を返す**ので、🔴 **最後の tick だけを出すと「3600s ago (limit 300s)」と
    # 赤に見えるのに緑**という形になる。**猶予の出どころを一緒に出す。**
    def test_tick_after_a_restart_shows_the_grace_it_is_measured_from
      Heartbeat.record_tick(now: now - 3600)
      Heartbeat.record_start(now: now - 5)

      assert_false(Heartbeat.tick_stale?(now))
      assert_match(
        /\A3600s ago \(started 5s ago, limit \d+s\)\z/,
        command.send(:format_tick, health),
      )
    end

    # 🔴 **起動直後の `never` は正常。**⚠⚠ **初回の tick は枠を回し終えるまで痕跡を
    # 書かない**ので、⚠ **何からの猶予を数えているのかを一緒に出す**
    # （→ `Heartbeat.tick_stale?`）。**ここが `never` だけだと、正常な起動直後と
    # 本物の詰まりが画面上で同じに見える。**
    def test_tick_without_a_trace_falls_back_to_the_start
      Heartbeat.record_start(now: now - 12)

      assert_match(/\Anever \(started 12s ago, limit \d+s\)\z/, command.send(:format_tick, health))
    end

    # ⚠ **どちらの痕跡も無ければ `never` だけ**（痕跡ファイルごと消えた形）。
    def test_tick_without_any_trace
      assert_match(/\Anever \(limit \d+s\)\z/, command.send(:format_tick, health))
    end

    # ⚠ **猶予は設定から出す**（`Health` 側と同じ理由 — 間隔を延ばした瞬間に画面の
    # 数字だけ置き去りになる形にしない）。
    def test_tick_limit_comes_from_the_setting
      config['/scheduler/tick_stale'] = '1h'
      Heartbeat.record_start(now: now - 60)
      Heartbeat.record_tick(now: now)

      assert_match(/\A0s ago \(limit 3600s\)\z/, command.send(:format_tick, health))
    end
  end
end
