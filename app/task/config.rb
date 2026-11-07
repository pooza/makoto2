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
        # ⚠ 弱い窓は落とさない（#255）。⚠ 枠を動かす PR の時点で見えるよう、ここでも出す。
        Scheduler.weak_conflicts(job).each do |window|
          puts "jobs: ⚠ #{job.name} (#{job.timetable}) overlaps a weak window (#{window})"
        end
      rescue => e
        rejected[job.name] = e
      end
      # ⚠ **壊れた弱い窓は落とさない**（投稿を止めない）。⚠ 枠ごとではなく 1 回だけ言う。
      CommentaryWindow.broken_weak.each do |window|
        puts "jobs: ⚠ weak commentary window #{window.name} is broken: #{window.error.message}"
      end
      if rejected.empty?
        puts "jobs: OK (#{jobs.size})"
      else
        # ⚠ **投稿の名前で始まらない文には名前を付ける**（#561）。⚠⚠ **強い窓そのものが壊れていると、
        # 全部の投稿が `commentary: <窓>: ...` の同じ文で落ち、どの投稿の行かが読めなかった。**
        rejected.each do |name, e|
          message = daemon.describe_rejection(e)
          named = message.start_with?("#{name}:", "scheduler: #{name} ")
          puts "jobs: #{named ? message : "#{name}: #{message}"}"
        end
        exit 1
      end
    end
  end
end
