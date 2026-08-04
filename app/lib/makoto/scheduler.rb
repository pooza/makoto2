module Makoto
  # 常駐プロセスに内蔵するスケジューラ。ハートビートと、枠に載せた投稿
  # （`PostingJob`）を回す。
  #
  # ⚠⚠ **枠ごとにジョブを登録しない。**ライブは 8 時間で 240 枠あり、枠の数だけ
  # 登録すると日をまたぐたびに登録し直すことになる（＝進行位置を状態として持つのと
  # 同じ）。**一定間隔で叩き（tick）、そのつど「いま枠の頭か」を時刻から計算する。**
  # ⚠ 落ちて戻ってきても位置がずれない（→ #10）。
  #
  # ⚠ **投稿の中身はここに書かない。**何を投稿するかはライブ（#13）・朝挨拶（#17）・
  # 曲紹介（#16）がそれぞれ `PostingJob` を作って `register` する。
  class Scheduler
    include Singleton
    include Package

    attr_reader :scheduler

    def exec
      schedule_heartbeat
      schedule_posts
      @scheduler.join
    end

    def shutdown
      @scheduler.shutdown(:kill)
    end

    # 投稿を登録する。⚠ `exec` の前に呼ぶこと。
    def register(job)
      @jobs.push(job)
      logger.info(scheduler: 'register', post: job.name, timetable: job.timetable.to_s)
      return self
    end

    def clear
      @jobs.clear
      return self
    end

    # 1 回ぶんの叩き。⚠⚠ **1 本の投稿が落ちても他を巻き込まない。**ライブ当日に
    # 1 本の例外で残りの枠を全部落とすのが最悪の壊れ方（→ docs/CLAUDE.md）。
    def tick(time = nil)
      time ||= Time.now
      return @jobs.map do |job|
        job.exec(time)
      rescue => e
        logger.error(scheduler: 'tick', post: job.name, error: e)
        next nil
      end
    end

    private

    def initialize
      @scheduler = Rufus::Scheduler.new
      @jobs = []
    end

    def schedule_heartbeat
      interval = config['/scheduler/heartbeat/interval']
      @scheduler.every interval, first: :now do
        logger.info(scheduler: 'heartbeat', version: Package.version, jobs: jobs)
      rescue => e
        logger.error(scheduler: 'heartbeat', error: e)
      end
    end

    # ⚠ 登録が 1 つも無ければ tick そのものを作らない。空回りのログを増やさない。
    def schedule_posts
      return nil if @jobs.empty?
      @scheduler.every config['/scheduler/tick'] do
        tick
      end
      return @jobs.size
    end

    # 登録された投稿の数。0 のままなら「常駐しているが何もしていない」状態が
    # 検知できる。⚠ ハートビート自身や tick は数えない。
    def jobs
      return @jobs.size
    end
  end
end
