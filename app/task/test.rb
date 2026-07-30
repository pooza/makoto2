module Makoto
  extend Rake::DSL

  desc 'test all'
  task :test do
    TestCase.load
  end
end
