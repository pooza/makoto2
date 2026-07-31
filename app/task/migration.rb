module Makoto
  extend Rake::DSL

  namespace :migration do
    desc 'migrate database'
    task run: [:db] do
      # ⚠ テストのメモリ DB と同じ経路（Database.migrate）を通す。sequel の CLI を
      # 別に叩くと、テストが通るスキーマと本番に当たるスキーマがずれる余地が残る。
      Database.migrate
      puts "migration: #{Environment.db}"
    end

    file :db do
      FileUtils.mkdir_p(File.dirname(Environment.db))
      FileUtils.touch(Environment.db)
    end
  end

  desc 'alias of migration:run'
  task migrate: ['migration:run']
end
