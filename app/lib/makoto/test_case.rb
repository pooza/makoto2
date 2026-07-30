require 'webmock'

module Makoto
  class TestCase < Ginseng::TestCase
    include Package
    include WebMock::API

    # ⚠ テストから外部へ実際のリクエストを飛ばさない。MAKOTO は投稿するボットなので、
    # 取りこぼすと本物のサーバーに書き込む（実際に 10 通投げてしまった）。
    #
    # `require 'webmock'` だけでは HTTP アダプタは差し替わらない。**`WebMock.enable!` を
    # 呼ぶまで `disable_net_connect!` も stub_request も無言で素通りする。**
    def setup
      WebMock.enable!
      WebMock.disable_net_connect!
    end

    def teardown
      WebMock.reset!
      WebMock.allow_net_connect!
      WebMock.disable!
      config.reload
    end

    def self.dir
      return File.join(Environment.dir, 'test')
    end
  end
end
