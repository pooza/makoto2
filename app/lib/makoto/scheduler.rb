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
      results = @jobs.map do |job|
        job.exec(time)
      rescue => e
        logger.error(scheduler: 'tick', post: job.name, error: e)
        next nil
      end
      record_tick
      return results
    end

    private

    # ⚠⚠ **tick が回ったこと自体を痕跡に残す**（#80 の黄 7）。⚠ **ハートビートは別の
    # rufus ジョブ**なので、**tick 側だけが詰まっても `at` は更新され続ける** —
    # 「生きているが投稿していない」の検知が、まさにその状態で効かなかった。
    #
    # ⚠ **投稿が 1 本も出なくても記録する。**ここで見たいのは**枠を見に行けているか**
    # であって、投稿の成否は別の痕跡が持つ（→ `Heartbeat` 冒頭の表）。
    # ⚠⚠ **書けなくても tick は止めない**（痕跡は観測のためのもの）。
    def record_tick
      Heartbeat.record_tick
    rescue => e
      logger.error(scheduler: 'tick', error: e)
    end

    def initialize
      @scheduler = Rufus::Scheduler.new
      @jobs = []
    end

    def schedule_heartbeat
      interval = config['/scheduler/heartbeat/interval']
      @scheduler.every interval, first: :now do
        logger.info(scheduler: 'heartbeat', version: Package.version, jobs: jobs)
        # ⚠ **監視はログではなくこの痕跡を見る**（→ `Heartbeat` / `Health`）。
        # 書けなくてもハートビートそのものは止めない（下の rescue の内側）。
        Heartbeat.touch(jobs: jobs)
      rescue => e
        logger.error(scheduler: 'heartbeat', error: e)
      end
    end

    # ⚠ 登録が 1 つも無ければ tick そのものを作らない。空回りのログを増やさない。
    def schedule_posts
      return nil if @jobs.empty?
      # ⚠⚠ **登録を先に済ませる。**下の初回の tick は投稿を伴うので、HTTP の再送で
      # 秒単位に伸びうる。⚠ **後に登録すると、伸びている間に次の枠が tolerance ごと
      # 過ぎて落ちる**（ライブの枠は 2 分間隔）。
      @scheduler.every config['/scheduler/tick'] do
        tick
      end
      # ⚠⚠ **最初の 1 回はここで叩く。**`every` は最初の間隔を待つので、これが無いと
      # 枠の頭 ＋ tolerance の内側で再起動したときに**その枠が落ちる**（→ #47）。
      # ⚠ 位置の計算そのものは正しいのに、**再起動直後にそれを呼ぶ機会が無い**という
      # 形で「落ちて戻ってきても位置がずれない」が効かなくなっていた。
      # ⚠ 初回が伸びて `every` の 1 回目と重なっても、**冪等キーが枠の頭の時刻から
      # 作られている**ので同じ枠は 1 通に畳まれる（→ `PostingJob#idempotency_key`）。
      tick
      return @jobs.size
    end

    # 登録された投稿の数。0 のままなら「常駐しているが何もしていない」状態が
    # 検知できる。⚠ ハートビート自身や tick は数えない。
    def jobs
      return @jobs.size
    end
  end
end
