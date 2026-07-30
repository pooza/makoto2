source 'https://rubygems.org'
ruby '>= 4.0', '< 5.0'
gem 'ginseng-core', github: 'pooza/ginseng-core', branch: 'main', require: 'ginseng'
gem 'ginseng-fediverse', github: 'pooza/ginseng-fediverse', branch: 'main',
  require: 'ginseng/fediverse'
# ⚠ MAKOTO は ricecream を使わない。ginseng-core の初期化が無条件に
# `require 'ricecream'` を実行するため、消すと `require 'ginseng'` が
# LoadError で落ちる。上流が直ったら外す（pooza/ginseng-core#483 / #22）。
# 同じ理由で :development に入れてもいけない（本番バンドルで落ちる）。
gem 'ricecream'
gem 'rufus-scheduler'
gem 'sequel'
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
