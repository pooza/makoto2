source 'https://rubygems.org'
ruby '>= 4.0', '< 5.0'
gem 'ginseng-core', github: 'pooza/ginseng-core', branch: 'main', require: 'ginseng'
gem 'ginseng-fediverse', github: 'pooza/ginseng-fediverse', branch: 'main',
  require: 'ginseng/fediverse'
# ⚠ 開発専用のつもりでも :development に入れてはいけない。ginseng-core の
# 初期化が `require 'ricecream'` を無条件に実行するため、development を外した
# バンドル（本番）では `require 'ginseng'` の時点で LoadError になる。
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
