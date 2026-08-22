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

    def health(alive: true)
      return Health.new(daemon: daemon(alive: alive), now: now)
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
    def status_output(alive: true)
      stub = health(alive: alive)
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

      ['running (PID ', 'jobs: ', 'heartbeat: ', 'tick: ', 'posting: ', 'orphans: '].each do |line|
        assert_include(output, line)
      end
    end

    def test_tick_with_a_trace
      Heartbeat.record_tick(now: now - 90)

      assert_match(/\A90s ago \(limit \d+s\)\z/, command.send(:format_tick, health))
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
      Heartbeat.record_tick(now: now)

      assert_match(/limit 3600s/, command.send(:format_tick, health))
    end
  end
end
