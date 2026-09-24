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
      #
      # 🔴 **落ちたものを全部並べる**（#350）。⚠⚠ **以前は `ConfigError` だけを受けていた**ので、
      # **別名表がディレクトリ（`Errno::EISDIR`）などは `jobs: ...` の 1 行ではなく rake の
      # バックトレースで落ちていた。**⚠ **常駐はこれらを見送って上がる**（→ `MakotoDaemon#register_jobs`）
      # ので、**ここが拾う口。**
      daemon = MakotoDaemon.new
      jobs, rejected = daemon.build_jobs
      jobs.each do |job|
        Scheduler.validate_window(job)
      rescue => e
        rejected[job.name] = e
      end
      if rejected.empty?
        puts "jobs: OK (#{jobs.size})"
      else
        rejected.each_value {|e| puts "jobs: #{daemon.describe_rejection(e)}"}
        exit 1
      end
    end
  end
end
