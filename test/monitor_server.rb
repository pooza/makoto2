require 'socket'

module Makoto
  class MonitorServerTest < TestCase
    teardown do
      @server&.stop
    end

    def server
      @server ||= MonitorServer.new
      return @server
    end

    # ⚠ **実際に叩いて確かめる。**⚠⚠ **WebMock は素の TCPSocket を横取りしない**ので、
    # ここは本物の口が開いていることを見ている（外へは 1 通も出ない）。
    def request(port, path)
      socket = TCPSocket.new(config['/monitor/bind'], port)
      socket.write("GET #{path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      return socket.read
    ensure
      socket&.close
    end

    # ⚠ **0 番で起こす。**固定のポートで起こすと、稼働中の常駐や他のテストと衝突する。
    def start_on_ephemeral_port
      config['/monitor/port'] = 0
      server.start
      return server.ports.first
    end

    def test_defaults
      assert_true(server.enabled?)
      # ⚠⚠ **既定で外に開けない。**開けるのは箱ごとに local.yaml へ書く明示的な一手。
      assert_equal('127.0.0.1', server.bind)
      assert_equal(4567, server.port)
    end

    def test_serves_healthz
      port = start_on_ephemeral_port

      assert_not_nil(port)
      response = request(port, '/healthz')

      assert_include(response, 'HTTP/1.1')
      assert_match(%r{HTTP/1\.1 (200|503)}, response)
    end

    def test_serves_not_found
      port = start_on_ephemeral_port
      response = request(port, '/makoto')

      assert_include(response, '404')
      assert_include(response, 'Not Found')
    end

    # ⚠⚠ **常駐が畳まれたら口も閉じること。**⚠ 開いたまま残ると、**死んだ常駐の代わりに
    # 孤児が 200 を返す**形が作れてしまう（→ MonitorServer）。
    def test_stop_closes_the_port
      port = start_on_ephemeral_port
      server.stop

      assert_empty(server.ports)
      assert_raise(Errno::ECONNREFUSED) {request(port, '/healthz')}
    end

    def test_disabled_does_not_listen
      config['/monitor/enabled'] = false

      assert_nil(server.start)
      assert_empty(server.ports)
    end

    # ⚠ **口が起こせなくても常駐は止めない。**⚠⚠ ポートが埋まっている程度のことで
    # 投稿を止めるほうが害が大きい（Kuma からは接続に失敗して赤く見える）。
    def test_start_failure_does_not_raise
      config['/monitor/bind'] = '203.0.113.1'
      config['/monitor/port'] = 4567

      assert_nothing_raised {server.start}
      assert_empty(server.ports)
    end
  end
end
