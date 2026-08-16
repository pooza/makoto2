require 'puma'
require 'puma/server'

module Makoto
  # 監視の口（`MonitorApp`）を常駐の中で起こす（#84）。手本は tomato-shrieker。
  #
  # ⚠⚠ **別プロセスにしない。**常駐が落ちれば口も一緒に閉じるので、⚠ **TCP の接続が
  # 失敗すること自体が「死んでいる」の検知**になる。⚠⚠ **別プロセスにすると、常駐が
  # 死んでいるのに口だけ生きて 200 を返す**という、いちばん悪い形が作れてしまう。
  #
  # ⚠ **口が起こせなくても常駐は止めない。**ポートが埋まっている程度のことで**投稿を
  # 止めるほうが害が大きい。**⚠⚠ **黙って見逃すことにもならない** — 口が無ければ
  # Kuma は接続に失敗して赤くなる（→ `MonitorApp`）。
  class MonitorServer
    include Package

    PREFIX = '/monitor'.freeze

    # ⚠⚠ **`optional_config` を使わない。**⚠ **設定を消しただけで監視の口が静かに
    # 閉じる形にしない**（`/scheduler/posting/failure_limit` と同じ判断 → #77 の裏返し）。
    # **schema で必須にしてあるので `rake config:lint` が先に止める。**
    def enabled?
      return config["#{PREFIX}/enabled"]
    end

    def bind
      return config["#{PREFIX}/bind"]
    end

    def port
      return config["#{PREFIX}/port"]
    end

    # 実際に待ち受けているポート。⚠ **テストが 0 番（任意のポート）で起こすので、
    # 設定値ではなく実体を返す。**
    def ports
      return @server&.connected_ports || []
    end

    def start
      # ⚠ **切ったこともログに残す。**⚠⚠ **「ポートが開かない」を設定で切ったせいだと
      # 切り分けられないと、Kuma の赤が常駐の異常に見える。**
      unless enabled?
        logger.info(monitor: 'disabled')
        return nil
      end
      @server = Puma::Server.new(MonitorApp.new)
      @server.add_tcp_listener(bind, port)
      @server.run
      logger.info(monitor: 'start', bind: bind, port: ports.first)
      return @server
    rescue => e
      # ⚠ **起こせなかったものを掴んだままにしない。**待ち受けていない `Puma::Server`
      # を `stop` が畳もうとする形になる。
      @server = nil
      logger.error(monitor: 'start', error: e)
      return nil
    end

    def stop
      return nil unless @server
      logger.info(monitor: 'stop')
      @server.stop(true)
      @server = nil
      return nil
    end
  end
end
