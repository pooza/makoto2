module Makoto
  extend Rake::DSL

  namespace :migration do
    desc 'migrate database'
    task run: [:db] do
      path = File.join(Environment.dir, 'app/migration')
      # マイグレーションが 1 本も無い間は sequel が「ファイルが見つからない」で落ちる。
      # スキーマ設計は #8 なので、それまでは空を正常として扱う（握り潰さず、その旨を出す）。
      if Dir.glob(File.join(path, '*.rb')).empty?
        puts 'migration: no migration files yet'
        next
      end
      sh "bundle exec sequel -m #{path} '#{Environment.dsn}' -E"
    end

    file :db do
      FileUtils.touch(Environment.db)
    end
  end

  desc 'alias of migration:run'
  task migrate: ['migration:run']
end
