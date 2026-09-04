module Makoto
  # MAKOTO の常駐プロセス。start / stop / restart / status は Ginseng::Daemon が持つ。
  # プロセスは 1 本だけで、投稿のスケジュールはこの中の Scheduler が回す。
  class MakotoDaemon < Ginseng::Daemon
    include Package
    include ProcessIdentity

    # @param proc_dir [String] プロセスの一覧を読む場所。⚠ **テストが差し替える**
    def initialize(opts = {})
      super
      @proc_dir = opts[:proc_dir] || ProcessIdentity::PROC_DIR
    end

    # pid ファイルが指すプロセスの状態。⚠ **上流の `:alive` / `:dead` / `:unknown`
    # に「身元」を足す**（#80 の黄 6）。
    #
    # 🔴 **番号だけでは足りない。**⚠⚠ **`Process.alive_state` は「その番号が在るか」
    # しか見ない**ので、⚠ **pid が再利用されると無関係なプロセスを常駐だと答える**
    # （実測 — `sleep 300` の pid を pid ファイルに書くと `running (PID 354866)`）。
    #
    # ⚠⚠ **倒れ方が静かなのが問題だった** — `run_start` が「already running」で
    # 終了し、⚠ **systemd の `Restart=always` が 5 秒ごとに叩き直す**ので、
    # 🔴 **ボットは一度も起動せず、理由もログに残らない**（warn は stderr →
    # `bin/makoto_daemon.rb` が `/dev/null` に落とす）。
    #
    # 🔴 **`alive?` ではなくここを上書きする**（#101 / 2026-08-24）。⚠⚠ **上流が
    # 起動と停止の判断に使うのは `alive_state` のほう**（`abort_if_running!` /
    # `run_restart` / `run_status`）で、⚠ **`alive?` は「真偽 2 値のまま残した
    # 既存の呼び出し側のため」の薄い述語**にすぎない。**あちらを上書きしても
    # `run_start` は守れない。**
    #
    # ⚠ **`:unknown`（`EPERM` ＝ 居るが触れない）はそのまま返す** — 🔴 **上流は
    # `:unknown` でも起動しない**（触れないだけで生きている可能性がある）。
    # ⚠⚠ **#111 で「`EPERM` は生きている」と自分の箱で塞いだ判断は、
    # `:unknown` という 3 つ目の答えとして上流に入った。**
    def alive_state
      state = super
      return state unless state == :alive
      return daemon_pid?(pid, proc_dir: @proc_dir) ? :alive : :dead
    end

    def command
      return nil
    end

    def motd
      return [
        "#{Package.full_name} (#{Environment.type})",
        ('Ruby YJIT: Ready' if Environment.jit?),
      ].compact.join("\n")
    end

    def start(args = [])
      logger.info(daemon: app_name, version: Package.version, message: 'start')
      # 🔴 **設定を起動時に 1 回検証する**（#99）。⚠ **止めない**（→ `validate_config`）。
      validate_config
      # ⚠ 登録より先に繋ぐ。原稿を引く口（`MessageSelector`）が接続を要る。
      connect_db
      register_jobs
      # ⚠ 監視の口は登録のあとに開ける（#84）。⚠⚠ **先に開けると、まだ 0 本の
      # `jobs` を見た `/healthz` が「投稿を 1 本も持たない」と赤くする。**
      #
      # 🔴 **起き上がったことを、口を開ける前に記録する**（PR #98 の Codex 指摘）。
      # ⚠⚠ **初回の tick は枠を全部回し終えるまで痕跡を書かない**ので、これが無いと
      # ⚠ **口を開けた直後から「tick が止まっている」と赤くなる**
      # （→ `Heartbeat.record_start`）。
      record_start
      monitor_server.start
      # 🔴 **トークンが生きているかを起き上がりで 1 回見る**（#106）。
      # ⚠ **投稿はしないので副作用は無い。**
      verify_credentials
      Scheduler.instance.exec
    rescue => e
      logger.error(daemon: app_name, error: e)
      raise
    end

    # ⚠ `run_start` の trap から同じインスタンスの `stop` が呼ばれる（→ Ginseng::Daemon）
    # ので、⚠⚠ **常駐が畳まれるときに監視の口も一緒に閉じる。**
    def stop
      logger.info(daemon: app_name, version: Package.version, message: 'stop')
      monitor_server.stop
      Scheduler.instance.shutdown
    end

    def monitor_server
      @monitor_server ||= MonitorServer.new
      return @monitor_server
    end

    # 常駐が回す投稿を並べる。
    #
    # ⚠ **投稿の中身はここに書かない。**何を投稿するかは各機能が自分の `PostingJob`
    # を作って持つ（→ `Scheduler`）。ここは並べるだけ。
    # ⚠ **`Scheduler#exec` より前に呼ぶこと**（登録が 0 本だと tick そのものが作られない）。
    def register_jobs
      Scheduler.instance.register(Announcement.new.job)
      # ⚠ 朝挨拶は毎朝 1 本（#17）。⚠⚠ **枠は毎日あるが、原稿が 1 件も無ければ
      # 何も返さない**（→ Morning / MessageSelector）。
      Scheduler.instance.register(Morning.new.job)
      # ⚠ 曲紹介は 1 日 2 本（#16）。⚠⚠ **前置きの原稿が 0 件でも曲だけを出す**
      # （→ Song / SongSource）。🔴 **原稿が無いことでは黙らない。**
      Scheduler.instance.register(Song.new.job)
      # ⚠ ライブは 4 本（前日増量・開始告知・8 時間の進行・終了告知）。
      # ⚠⚠ **どれも枠は毎日あるが、ライブ当日以外は何も返さない**（→ Live）。
      Live.new.jobs.each {|job| Scheduler.instance.register(job)}
      return Scheduler.instance
    end

    private

    # 🔴 **確かめた pid にだけ送る**（#162 / #169 / Codex の P1）。
    #
    # ⚠⚠ **`TERM` を送ってから pid ファイルを消す・`EPERM` では消さない**という
    # #111 の 2 点は、✅ **上流（`pooza/ginseng-core#509` / `#532`）に入った**ので
    # **`run_stop` ごと上流に任せる**（⚠ **消すのは「中身がまだその pid のときだけ」**
    # という後継との競り合いの手当ても向こうにある）。⚠ **こちらに残るのは
    # 身元の判定だけ** — **上流は pid ファイルの番号をそのまま信じて送る。**
    #
    # 🔴 **判定は「送る 1 点」に置く。**⚠⚠ **`run_stop` を上書きして手前で確かめる形
    # にすると、確かめた pid と実際に送る pid が別物になりうる** — ⚠ **上流の
    # `run_stop` は pid ファイルを読み直す**ので、**確かめてから送るまでの間に
    # 後継が新しい pid を書けば、身元を確かめていない相手へ `TERM` が飛ぶ。**
    # ⚠⚠ **まさに `remove_pid(expected)`（上流 `#532`）が相手にしている競り合い。**
    def send_signal(signal, target)
      return nil unless stoppable?(target)
      return super
    end

    # 🔴 **その pid へ `TERM` を送ってよいか**（#162 / #169）。
    #
    # ⚠⚠ **`alive_state` には #80 の黄 6（pid の再利用）と黄 3（`0`）を塞いだが、
    # `run_stop` はそこを通らない** — ⚠ **`run_restart` は `run_stop unless
    # alive_state == :dead` なので身元を見た結果で呼ばれるが、`bin/makoto_daemon.rb
    # stop` を直に叩く経路は素通しだった。**
    #
    # 🔴 **`pid` は `File.read(pid_file).to_i` なので、空も壊れた文字列も `0`。**
    # ⚠⚠ **`0` は truthy なので `run_stop` 冒頭の `unless` を抜け、
    # `Process.kill('TERM', 0)` ＝ 呼び出し元のプロセスグループ全体に TERM を送る。**
    # ⚠ **人が手で止める経路と復旧のラッパーが踏む**（systemd は `ExecStop` を
    # 書いていないので通らない）。
    #
    # 🔴 **確かめられなかったときも送らない**（Codex の P1・#169）。⚠⚠ **`daemon_pid?`
    # は「確かめられない」を `true` に倒す** — ⚠ **それは `alive?` にとっては正しい**
    # （二重起動を避けるほうが重い）が、🔴 **止める側は破壊的なので、確かめられないなら
    # 何もしないほうが安全。**⚠ **そのときは pid ファイルを残す**（`EPERM` の枝と同じ。
    # ⚠⚠ **消した瞬間に孤児が確定する**）。
    def stoppable?(target)
      unless identifiable?(target)
        warn "#{app_name} (PID #{target}) could not be identified. PID file kept."
        exit 1
      end
      return true if daemon_pid?(target, proc_dir: @proc_dir)
      # ⚠ **確かめて別物だったなら掃除してよい**（`ESRCH` の枝と同じ扱い）。⚠⚠ **残すと
      # `run_start` が「already running」で無言終了する**（#80 の黄 6 で踏んだ形）。
      #
      # 🔴 **ただし「まだその番号のときだけ」消す**（#199）。⚠⚠ **`expected` を渡さない
      # と後継が書いた pid ファイルまで消す** — ⚠ **後継は生きたままどの pid ファイル
      # からも辿れなくなり、孤児が確定する**（🔴 **次の `run_start` は
      # `abort_if_running!` を素通りするので 2 本目が立つ**）。⚠ **`send_signal` の
      # コメントが挙げている競り合いは、まさにこの引数が相手にしているもの。**
      remove_pid(target)
      warn "PID file found, but PID #{target} is not #{app_name}."
      return false
    end

    # 身元を**確かめられたか**（#169）。⚠⚠ **「確かめて別物だった」とは区別する** —
    # **`daemon_pid?` は両方を混ぜて `true` / `false` に畳んでしまう。**
    #
    # | | `identifiable?` | `daemon_pid?` | `run_stop` |
    # | --- | --- | --- | --- |
    # | `/proc` が無い | **false** | true | 🔴 **送らない・pid ファイルは残す** |
    # | `/proc/{pid}` が読めない（`EACCES`） | **false** | true | 🔴 **送らない・pid ファイルは残す** |
    # | `/proc/{pid}` の stat が拒まれる | **false** | true | 🔴 **送らない・pid ファイルは残す** |
    # | `/proc/{pid}` が無い（もう居ない） | true | true | 送る → `ESRCH` → 掃除 |
    # | argv が読めて別物 | true | **false** | 送らない・掃除 |
    # | argv が読めて常駐 | true | true | ✅ **送る** |
    #
    # ⚠ **「もう居ない」を false にしない。**⚠⚠ **そこを送らずに pid ファイルを残すと、
    # `run_start` が「already running」で無言終了する**（#80 の黄 6 で踏んだ形）。
    # 🔴 **確かめられなかったのではなく、確かめて「居ない」と分かった状態。**
    def identifiable?(target)
      return false unless File.directory?(@proc_dir)
      entry = File.join(@proc_dir, target.to_s)
      return true unless proc_entry?(entry)
      argv(entry)
      return true
    rescue SystemCallError
      return false
    end

    # `/proc/{pid}` が**在るか**（#169・Codex の 2 巡目）。
    #
    # 🔴 **`File.directory?` を使わない。**⚠⚠ **あれは「無い」も「stat を拒まれた」も
    # 同じ false に畳む** — ⚠ **拒まれたほうが「もう居ない」に化け、`identifiable?`
    # が true を返して `TERM` が飛ぶ**（＝ この PR が畳もうとしている形が、
    # 1 段下に残っていた）。
    #
    # ⚠ **`ENOENT` だけを「確かめて、居ないと分かった」に倒し**、⚠⚠ **それ以外の
    # `SystemCallError` は呼び元の `rescue` へ抜けさせる**（＝ 確かめられなかった）。
    def proc_entry?(entry)
      return File.stat(entry).directory?
    rescue Errno::ENOENT
      return false
    end

    # 設定を起動時に 1 回検証する（#99）。
    #
    # ⚠⚠ **`rake config:lint` は開発機で流すもの**で、⚠ **稼働ホストにしか無い
    # `config/local.yaml` は検証を一度も通っていなかった。**
    #
    # 🔴 **通らなくても常駐は止めない**（2026-08-21・オーナー判断）。⚠⚠ **止めると
    # systemd の `Restart=always` が 5 秒ごとに叩き直す形**になり、⚠ **11/4 当日に
    # 踏むと復旧の時間が要る。**⚠⚠ **代わりに `/healthz` を赤にする**（→ `Health`）。
    #
    # ⚠ **ここで例外にしない**のは `record_start` と同じ扱い（痕跡が書けないことで
    # 常駐が上がらないのを避ける）。
    def validate_config
      found = config.validation_errors
      return found if found.empty?
      logger.error(daemon: app_name, config: 'invalid', count: found.size, errors: found)
      return found
    rescue => e
      # ⚠⚠ **検証そのものが落ちても常駐は上げる。**⚠ schema が読めないだけで
      # ボットが動かなくなるほうが痛い。
      logger.error(daemon: app_name, config: 'unverified', error: e)
      return []
    end

    # トークンの失効を起き上がりで見に行く（#106）。⚠ **`verify_credentials` は
    # 投稿しない**ので、**叩いても当日の並びに影響しない。**
    #
    # 🔴 **これが無いと、失効に気付くのが 11/3 になる。**⚠ **8/15〜10/31 は 1 本も
    # 投稿しない**ので痕跡が出ず、⚠⚠ **予告は 1 日 1 枠なので `failure_limit: 3` に
    # 届くのに 3 日かかる**（11/1 → 11/3）。**気付いたときには前日。**
    #
    # ⚠⚠ **別スレッドで投げる。**🔴 **ここで待つと最悪 93 秒**（timeout 30 秒 × 再送 3）
    # **初回の tick が遅れ、枠の頭 ＋ 拾う幅を過ぎて 1 枠落ちる**（→ #47 / #92）。
    #
    # ⚠ **失効（401 / 403）とそれ以外を分ける。**⚠⚠ **「Mastodon が落ちている」が
    # 「トークンが死んでいる」に化けると、当日いちばん困る**（→ #124 と同じ形）。
    # ⚠ **どちらでも常駐は止めない**（痕跡が書けないときと同じ扱い）。
    #
    # ⚠ **`/healthz` には載せない**（#106 で明示）。**Mastodon 側の一時的な不調で
    # 「復旧させる」が叩かれる**ので、**ログに残すだけにする。**
    #
    # @return [Thread] ⚠ テストが待ち合わせに使う
    def verify_credentials
      return Thread.new do
        account = MastodonService.new.account
        logger.info(mastodon: 'verify_credentials', acct: account['acct'],
          statuses: account['statuses_count'])
      rescue Ginseng::AuthError => e
        logger.error(mastodon: 'verify_credentials', message: 'token is not valid', error: e)
      rescue => e
        logger.warn(mastodon: 'verify_credentials', message: 'could not verify the token', error: e)
      end
    end

    # 起き上がったことを痕跡に残す（→ `Heartbeat.record_start`）。
    #
    # 🔴 **書けなくても常駐は止めない**（リリース前レビューの黄 1）。⚠⚠ **痕跡は
    # 観測のためのもの**なので、**`Scheduler` 側の `record_tick` / `touch` はどちらも
    # rescue の内側に置いてある**（`test/scheduler.rb` が「痕跡が書けなくても tick は
    # 止めない」を保証している）。⚠ **ここだけ素で呼ぶと、`tmp/run` が書けないだけで
    # `start` の rescue が再送出し**、🔴 **監視の口も投稿も立ち上がらないまま
    # systemd が 5 秒ごとに叩き直す**（警告は stderr → `/dev/null`）。
    def record_start
      Heartbeat.record_start
      return nil
    rescue => e
      logger.error(daemon: app_name, error: e)
      return nil
    end

    # ⚠ **投稿の経路が使うのと同じ接続を掴む**（#80 の緑 5）。
    #
    # 🔴 **以前はここで別に `Sequel.connect` して PRAGMA を当てていたが、その接続は
    # 誰も使っていなかった** — ⚠⚠ **原稿を引く口が使うのは `Database.connection` の
    # ほう**なので、**WAL も busy_timeout も効いていなかった。**⚠ **PRAGMA は
    # `Database.connect` に移した**ので、**この先増やすぶんも空振りしない。**
    def connect_db
      return Database.connection
    end
  end
end
