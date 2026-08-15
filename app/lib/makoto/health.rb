module Makoto
  # 常駐の健全性。**監視（monit / Uptime Kuma）が叩く口**であり、`makoto status` の
  # 中身でもある。
  #
  # ⚠⚠ **「プロセスが生きているか」だけでは足りない。**systemd の `Restart=always` は
  # プロセスの死しか見ないので、**常駐したまま何もしていない**状態を拾えない。
  # ⚠ 実際に 2026-08-05〜08 の 3 日間、`jobs: 0`（投稿の登録が 0 本）のまま生きていた
  # （→ #15）。**「生きている」と「仕事をしている」を分けて見る。**
  #
  # ## 終了コード
  #
  # | 値 | 意味 | 監視の扱い |
  # | --- | --- | --- |
  # | 0 | 健全 | 何もしない |
  # | 1 | ⚠ **異常** — 死んでいる／投稿を 1 本も持たない／ハートビートが止まった | **復旧させる** |
  # | 2 | ⚠ **警告** — 孤児プロセスがある | **人が見る。復旧は叩かせない** |
  #
  # ⚠⚠ **孤児で復旧を叩かせないのは、再起動の瞬間に一時的に 2 本になりうるから。**
  # ここで再起動を叩くと、検知 → 再起動 → 検知のループになる。⚠ **孤児は「溜まる」
  # のが問題**（旧実装は 11 日分溜めた）なので、即時の自動復旧より人の目が要る。
  class Health
    include Package

    OK = 0
    ERROR = 1
    WARNING = 2

    PROC_DIR = '/proc'.freeze
    # ⚠ 常駐の実体。`bin/makoto` の CLI とは別物なので、これで CLI 自身は拾わない。
    PROCESS_NAME = 'makoto_daemon.rb'.freeze

    # ⚠⚠ **argv の先頭 2 つしか見ない**（#61）。
    #
    # ⚠ **cmdline の部分一致にすると、argv にこの文字列を含むだけの無関係なプロセスを
    # 孤児と報告する**（実測）。⚠⚠ **踏みやすいのは運用側の経路** — 復旧のラッパー
    # スクリプト・デプロイのシェル・`pgrep` のワンライナー。**docs が「復旧コマンドは
    # ラッパースクリプトに逃がす」と決めている以上、この形は運用に組み込まれる。**
    #
    # ⚠ **見るのは「実行されているスクリプト」で、それは argv の 0 番目か、
    # インタプリタの次**（`ruby bin/makoto_daemon.rb start`）。**3 つ目以降に出るのは
    # 引数や `-c` の文字列**なので、そこまで見ると部分一致に戻ってしまう。
    PROCESS_ARGV_DEPTH = 2

    attr_reader :daemon

    # @param proc_dir [String] プロセスの一覧を読む場所。⚠ **テストが差し替える**
    def initialize(daemon: nil, now: nil, proc_dir: PROC_DIR)
      @daemon = daemon || MakotoDaemon.new
      @now = now
      @proc_dir = proc_dir
    end

    def now
      return @now || Time.now
    end

    def pid
      return @daemon.pid
    end

    def alive?
      return @daemon.alive?
    end

    def jobs
      return Heartbeat.jobs
    end

    def heartbeat_age
      return Heartbeat.age(now)
    end

    # pid ファイルに無い常駐プロセス。⚠ **旧実装が孤児プロセスを 11 日分撒いた件の
    # 再発検知**（→ docs/CLAUDE.md「プロセスの寿命を設計に含める」）。
    #
    # ⚠⚠ **`/proc` が読めない環境では nil を返す。**「孤児は無い」と嘘をつくと、
    # 監視しているつもりで無防備になる。
    def orphans
      return nil unless File.directory?(@proc_dir)
      unreadable = false
      found = Dir.glob(File.join(@proc_dir, '[0-9]*')).filter_map do |dir|
        orphan_pid(dir)
      rescue Errno::EACCES
        unreadable = true if File.owned?(dir)
        next nil
      rescue SystemCallError
        unreadable = true
        next nil
      end
      return found.sort if found.any?
      return nil if unreadable
      return []
    rescue SystemCallError
      return nil
    end

    # 復旧させるべき問題。⚠ **空なら健全。**
    def errors
      results = []
      return results.push("#{@daemon.app_name} is not running") unless alive?
      results.push('heartbeat is stale') if Heartbeat.stale?(now)
      results.push('no posting job is registered') if jobs.to_i.zero?
      return results
    end

    # 人が見るべき問題。⚠ **復旧は叩かせない。**
    def warnings
      found = orphans
      return ['cannot read /proc (orphan check skipped)'] if found.nil?
      return [] if found.empty?
      return ["orphan process: #{found.join(', ')}"]
    end

    def code
      return ERROR if errors.any?
      return WARNING if warnings.any?
      return OK
    end

    private

    def orphan_pid(dir)
      found = File.basename(dir).to_i
      return nil if found.zero?
      return nil if found == pid
      return nil if found == Process.pid
      return nil unless daemon?(argv(dir))
      return found
    end

    # その argv は常駐のものか（→ 上記 `PROCESS_ARGV_DEPTH`）。
    #
    # ⚠⚠ **1 要素の中を空白で割ってから見る。**実機の常駐は
    # **argv が `bin/makoto_daemon.rb start` という 1 要素**になっている（bundler 経由の
    # 起動で `$0` が書き換わるため。2026-08-15 に bydo の `/proc` を実測）。
    # ⚠ **要素をそのまま突き合わせると、本物の孤児を取り逃がす。**
    def daemon?(argv)
      return argv.first(PROCESS_ARGV_DEPTH).any? do |arg|
        File.basename(arg.split.first.to_s) == PROCESS_NAME
      end
    end

    # ⚠ `/proc/{pid}/cmdline` は NUL 区切り。**末尾に NUL の詰め物が付く**ので空要素を落とす。
    # ⚠ `ENOENT` / `ESRCH` は無視する。**列挙してから消えるプロセスがある。**
    # ⚠⚠ **`EACCES` は握らない**（読めなかったことを `orphans` 側に伝える → #54）。
    def argv(dir)
      return File.read(File.join(dir, 'cmdline')).split("\0").reject(&:empty?)
    rescue Errno::ENOENT, Errno::ESRCH
      return []
    end
  end
end
