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

    # ⚠⚠ **例外は 503 に倒す。**⚠ **200 に倒すと、`Health` が落ちている間だけ監視が
    # 緑になる** — 設定の欠落（#77）やハートビートの閾値の不正で `Health` 自身が
    # 例外を上げうるので、**判定できないことを健全と答えない。**
    #
    # ⚠ **ここでしかログを書かない。**Kuma は 1 分ごとに叩くので、⚠⚠ **正常な応答を
    # 書くと 1 日 4,000 行を超え、平常日のログが監視で埋まる。**
    def respond
      messages = yield(@health.call)
      return [200, HEADERS, ["OK\n"]] if messages.empty?
      return [503, HEADERS, ["#{messages.join("\n")}\n"]]
    rescue => e
      logger.error(monitor: 'healthz', error: e)
      return [503, HEADERS, ["#{error_message(e)}\n"]]
    end
  end
end
