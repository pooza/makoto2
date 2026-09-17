module Makoto
  extend Rake::DSL
  include Package

  namespace :config do
    desc 'lint local config'
    task :lint do
      puts "environment: #{Environment.type}"
      if config.errors.present?
        puts 'config:'
        puts config.errors.to_yaml
        exit 1
      else
        puts 'config: OK'
      end
      # 🔴 **常駐と同じ投稿を 1 回作る**（#276）。⚠⚠ **スキーマで書けない相互条件**
      # （`/message/anniversary` の登録・`/track/weight` と `/song/kind_types`・実況の窓・
      # 履歴のテーブル）**は、ここを通さないと常駐の起動で初めて落ちる**（→ `MakotoDaemon#jobs`）。
      begin
        jobs = MakotoDaemon.new.jobs
        jobs.each {|job| Scheduler.validate_window(job)}
        puts "jobs: OK (#{jobs.size})"
      rescue Ginseng::ConfigError => e
        puts "jobs: #{e.message}"
        exit 1
      end
    end
  end
end
