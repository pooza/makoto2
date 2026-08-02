source 'https://rubygems.org'
ruby '>= 4.0', '< 5.0'
gem 'ginseng-core', github: 'pooza/ginseng-core', branch: 'main', require: 'ginseng'
gem 'ginseng-fediverse', github: 'pooza/ginseng-fediverse', branch: 'main',
  require: 'ginseng/fediverse'
gem 'rufus-scheduler'
gem 'sequel'
# rufus-scheduler の依存として入るが、Timetable が直接使うので明示する。
gem 'tzinfo'
gem 'sqlite3'
gem 'thor'

group :development do
  gem 'rubocop'
  gem 'rubocop-minitest'
  gem 'rubocop-performance'
  gem 'rubocop-rake'
  gem 'rubocop-sequel'
  gem 'test-unit'
  gem 'webmock'
end
