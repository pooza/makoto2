module Makoto
  # 監視（Uptime Kuma）が叩く HTTP の口（#84）。**中身は `Health` をそのまま写す。**
  #
  # ⚠⚠ **`makoto status` は箱の中からしか呼べない。**死活の判断そのものは `Health` に
  # あるのに、**外から確かめる手段が無かった**（→ #15）。⚠ **monit は fleet 全体で
  # 退役方向で、Kuma のモニタは 99 本すべてが `http`**（push の前例はゼロ）なので、
  # **Kuma に載せるには HTTP の口が要る。**
  #
  # ## ⚠⚠ これは「inbound は開けない」を緩める判断
  #
  # ⚠ **緩めるのは LAN 限定・読み取り専用の死活の口だけ。**⚠⚠ **管理コンソールは
  # 作らない**（この決定は変えていない → docs/CLAUDE.md「管理操作は CLI で行う」）。
  # ⚠ **既定は `127.0.0.1`** で、開けるのは箱ごとに `config/local.yaml` へ書く明示的な
  # 一手にしてある（→ `MonitorServer`）ので、**「開いていない」が既定のまま残る。**
  #
  # ## 口を 3 つに分ける（2026-08-16 決定）
  #
  # | 口 | 503 になる条件 | 監視の扱い |
  # | --- | --- | --- |
  # | `/healthz` | `Health#errors`（＝終了コード 1） | **復旧させてよい** |
  # | `/healthz/posting` | 投稿が続けて落ちている（＝ #78 の警告） | **人が見る** |
  # | `/healthz/orphans` | 孤児プロセスがある／`/proc` が読めない | **人が見る** |
  #
  # ⚠⚠ **投稿の警告と孤児を同じ口に載せない。**⚠ **投稿の警告は sticky で、消えるのは
  # 「次に 1 本投稿できたとき」だけ**（→ `Heartbeat`）。⚠⚠ **同じ口に載せると、赤の
  # まま何週間も残っている間に本物の孤児が埋もれる** — **溜まっていくことが問題の
  # 検知**（旧実装は 11 日分溜めた）が、いちばん効かなくなる。
  #
  # ⚠ **生死そのものは口の有無で分かる。**常駐が落ちれば TCP の接続ごと失敗するので、
  # ⚠⚠ **`/healthz` が実際に足すのは「生きているが仕事をしていない」の検知**
  # （ハートビートが止まった・投稿を 1 本も持たない）。
  class MonitorApp
    include Package

    HEADERS = {'content-type' => 'text/plain; charset=utf-8'}.freeze

    HEALTHZ = '/healthz'.freeze
    POSTING = '/healthz/posting'.freeze
    ORPHANS = '/healthz/orphans'.freeze

    # @param health [#call] `Health` を作るもの。⚠ **リクエストごとに呼ぶ。**
    #   ⚠⚠ **1 つを使い回すと、`Health` が痕跡を掴んだまま古い判定を返し続ける。**
    def initialize(health: nil)
      @health = health || -> {Health.new}
    end

    def call(env)
      case env['PATH_INFO']
      when HEALTHZ
        return respond(&:errors)
      when POSTING
        return respond(&:posting_warnings)
      when ORPHANS
        return respond(&:orphan_warnings)
      else
        return [404, HEADERS, ["Not Found\n"]]
      end
    end

    private

    # 🔴 **答えている自分が、pid ファイルの常駐かを先に確かめる**（2026-08-16・#87 の
    # レビュー指摘）。⚠⚠ **違えば、この口が返す答えは全部あてにならない。**
    #
    # ⚠ **口が塞がっていても常駐を止めない**（→ `MonitorServer`）ということは、
    # ⚠⚠ **古い常駐がポートを掴んだまま、新しい常駐がその横で動く形が作れる**という
    # こと。**そのとき Kuma に答えるのは古いほう**で、⚠ **痕跡も pid ファイルも新しい
    # ほうが書いている**ので、⚠⚠ **3 つの口が揃って 200 を返す。**
    #
    # ⚠ **孤児の口さえ緑になる** — `Health` は**自分自身（`Process.pid`）と pid ファイル
    # の常駐**を走査から除くので、**2 本ある状態が、どちらから見ても見えない。**
    # ⚠⚠ **monit が退役していて Kuma しか見ていない**以上、これは無防備そのもの。
    #
    # ⚠ **実測（2026-08-16）** — 2 本立てると `makoto status` は `orphan process: 912621`
    # で `2` を返したのに、⚠⚠ **`/healthz` / `/healthz/posting` / `/healthz/orphans` は
    # 3 つとも 200 だった。**
    #
    # ⚠ **再起動の一瞬（pid ファイルが消えている窓）もここに掛かる。**⚠⚠ **短い 503 は
    # 誤報ではない** — その瞬間、この口に答えているのは畳まれる途中の常駐。
    def stale_messages(health)
      return [] if health.pid == Process.pid
      found = health.pid || 'none'
      return ["monitor is served by a stale process (PID #{Process.pid}, pid file says #{found})"]
    end

    # ⚠⚠ **例外は 503 に倒す。**⚠ **200 に倒すと、`Health` が落ちている間だけ監視が
    # 緑になる** — 設定の欠落（#77）やハートビートの閾値の不正で `Health` 自身が
    # 例外を上げうるので、**判定できないことを健全と答えない。**
    #
    # ⚠ **ここでしかログを書かない。**Kuma は 1 分ごとに叩くので、⚠⚠ **正常な応答を
    # 書くと 1 日 4,000 行を超え、平常日のログが監視で埋まる。**
    def respond
      health = @health.call
      # ⚠ **身元が食い違うなら、そこで止める。**⚠⚠ **中身の答えを足しても意味が無い**
      # （その `Health` は別の常駐のことを見ている）。
      messages = stale_messages(health)
      messages = yield(health) if messages.empty?
      return [200, HEADERS, ["OK\n"]] if messages.empty?
      return [503, HEADERS, ["#{messages.join("\n")}\n"]]
    rescue => e
      logger.error(monitor: 'healthz', error: e)
      return [503, HEADERS, ["#{error_message(e)}\n"]]
    end
  end
end
