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
  # | 2 | ⚠ **警告** — 孤児プロセスがある／**投稿が続けて落ちている** | **人が見る。復旧は叩かせない** |
  #
  # ⚠⚠ **孤児で復旧を叩かせないのは、再起動の瞬間に一時的に 2 本になりうるから。**
  # ここで再起動を叩くと、検知 → 再起動 → 検知のループになる。⚠ **孤児は「溜まる」
  # のが問題**（旧実装は 11 日分溜めた）なので、即時の自動復旧より人の目が要る。
  #
  # ## ⚠ 投稿の失敗を「異常」ではなく「警告」に置く理由（#78）
  #
  # ⚠⚠ **再起動で直らないから。**投稿が落ちる原因は**トークンの失効・設定の欠落
  # （#77）・`source` の不具合・Mastodon 側の障害**で、**どれも常駐を入れ直しても
  # 変わらない。**⚠ ここを 1（復旧させる）にすると、**検知 → 再起動 → また失敗**を
  # 延々と繰り返し、⚠⚠ **ライブ当日には再起動のたびに初回 tick が走る**
  # （→ `Scheduler#schedule_posts`）。**孤児で復旧を叩かせないのと同じ形。**
  #
  # ⚠ **#78 の起票は `errors` に置く案だったが、上の理由で `warnings` にした。**
  # **検知できること自体が目的**で、**8 時間 1 回きりのライブでは、機械の再起動より
  # 人が見るほうが要る。**
  #
  # ## ⚠⚠ この警告は自然には消えない
  #
  # ⚠ **消えるのは「次に 1 本投稿できたとき」だけ。**時間で薄れない。
  # **MAKOTO は平常日でも数本しか投稿しない**ので、⚠⚠ **時間で消える形にすると
  # 「投稿していない期間」＝ 検証されていない期間に、警告のほうが先に消える。**
  # ⚠ **直したあと、次の枠が来るまで黄色が残るのは意図した挙動。**
  class Health
    include Package
    # ⚠ 孤児の判定に使う argv の規則。⚠⚠ **常駐自身の `alive?` も同じものを見る**
    # （→ `ProcessIdentity`・#80 の黄 6）。
    include ProcessIdentity

    OK = 0
    ERROR = 1
    WARNING = 2

    attr_reader :daemon

    # @param proc_dir [String] プロセスの一覧を読む場所。⚠ **テストが差し替える**
    def initialize(daemon: nil, now: nil, proc_dir: ProcessIdentity::PROC_DIR)
      @daemon = daemon || MakotoDaemon.new(proc_dir: proc_dir)
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

    # 最後の成功からの、連続した失敗の数。⚠ **本文の無い枠は数に入っていない。**
    def posting_failures
      return Heartbeat.failures
    end

    # 最後に投稿できた時刻。⚠ **一度も無ければ nil**（起動直後・原稿がまだ無い時期）。
    def posted_at
      return Heartbeat.posted_at
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
      results = []
      # ⚠ 死んでいるときは `errors` の側が言うので、ここでは重ねない。
      results.push(*posting_warnings) if alive?
      results.push(*orphan_warnings)
      return results
    end

    # 投稿が続けて落ちていること（#78）。⚠ **`warnings` から分けて取れるようにして
    # あるのは、HTTP の口を分けるため**（→ `MonitorApp`）。
    #
    # ⚠⚠ **この警告は sticky で、消えるのは「次に 1 本投稿できたとき」だけ。**孤児と
    # 同じ口に載せると、⚠ **赤のまま残っている間に本物の孤児が埋もれる。**
    def posting_warnings
      return [] unless Heartbeat.failing?
      return [posting_failure_message]
    end

    # 孤児プロセスがあること。⚠ **`/proc` が読めないときも黙らない**（→ `orphans`）。
    def orphan_warnings
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

    # ⚠ **「何本続けて落ちたか」と「最後に出たのはいつか」を両方出す。**
    # ⚠⚠ **人が見る前提の警告**なので、次に何を確かめればよいかがここで分かること。
    def posting_failure_message
      last = posted_at ? posted_at.getutc.iso8601 : 'never'
      return "posting failed #{posting_failures} times in a row (last success: #{last})"
    end

    def orphan_pid(dir)
      found = File.basename(dir).to_i
      return nil if found.zero?
      return nil if found == pid
      return nil if found == Process.pid
      return nil unless daemon?(argv(dir))
      return found
    end
  end
end
