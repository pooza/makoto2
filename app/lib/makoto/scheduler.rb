module Makoto
  # 常駐プロセスに内蔵するスケジューラ。投稿のジョブは #10 以降でここに登録する。
  # 骨組みの段階では、常駐が生きていることを示すハートビートだけを持つ。
  class Scheduler
    include Singleton
    include Package

    attr_reader :scheduler

    def exec
      schedule_heartbeat
      @scheduler.join
    end

    def shutdown
      @scheduler.shutdown(:kill)
    end

    private

    def initialize
      @scheduler = Rufus::Scheduler.new
    end

    def schedule_heartbeat
      interval = config['/scheduler/heartbeat/interval']
      @scheduler.every interval, first: :now do
        logger.info(scheduler: 'heartbeat', version: Package.version, jobs: jobs)
      rescue => e
        logger.error(scheduler: 'heartbeat', error: e)
      end
    end

    # ハートビート自身を除いたジョブ数。0 のままなら「常駐しているが何もしていない」
    # 状態が検知できる。
    def jobs
      return @scheduler.jobs.count - 1
    end
  end
end
