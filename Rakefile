$LOAD_PATH.unshift(File.join(File.expand_path(__dir__), 'app/lib'))
ENV['RAKE'] = 'yes'

require 'makoto'
module Makoto
  Sequel.connect(Environment.dsn)
  load_tasks
end
