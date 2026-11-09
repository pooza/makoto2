module Makoto
  extend Rake::DSL
  include Package

  namespace :config do
    desc 'lint local config'
    task :lint do
      puts "environment: #{Environment.type}"
      # 🔴 **`validation_errors` を見る**（#612・Codex の P2）。⚠⚠ **`errors` は schema だけ**で、
      # 期間の書き損じ（`Config#duration_errors`）を拾わない。⚠ 起動時の検査・`/healthz` と同じ口。
      found = config.validation_errors
      if found.present?
        puts 'config:'
        puts found.to_yaml
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
        # ⚠ 名前の付け方は `MakotoDaemon#lint_rejection`（#561・テストは #580）。
        rejected.each {|name, e| puts "jobs: #{daemon.lint_rejection(name, e)}"}
        exit 1
      end
    end
  end
end
