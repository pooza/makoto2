module Makoto
  class TestCase < Ginseng::TestCase
    include Package

    def teardown
      config.reload
    end

    def self.dir
      return File.join(Environment.dir, 'test')
    end
  end
end
