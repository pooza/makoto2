module Makoto
  # 常駐が**仕事をしている**ことの痕跡。ハートビートのたびに書き換える。
  #
  # ⚠⚠ **ログだけでは外から判定できない。**ハートビートは syslog に出ているが、
  # 監視から「最後に動いたのはいつか」を読むにはログの置き場と書式に依存することに
  # なる。**1 ファイルに最新の 1 件だけ持たせて、そこだけ見れば済むようにする。**
  #
  # ⚠ **これは「進行位置の状態」ではない。**投稿の進行位置は時刻から計算する
  # （→ `Timetable`）。ここに書くのは**観測のための痕跡だけ**で、消しても再起動後の
  # 動作は何も変わらない（→ docs/CLAUDE.md「投稿の欠落は詰めない」）。
  class Heartbeat
    include Package

    # ハートビートが止まったとみなすまでの倍率。⚠ **1 回の取りこぼしでは騒がない。**
    STALE_FACTOR = 3

    class << self
      # ⚠ **テストは別のファイルに落とす。**`Environment.db` と同じ理由で、稼働中の
      # 痕跡をテストが書き換えると `makoto status` が嘘をつく。
      def path
        name = Environment.test? ? 'heartbeat_test.json' : 'heartbeat.json'
        return File.join(Environment.dir, 'tmp/run', name)
      end

      # ⚠ **呼ぶ側（`Scheduler`）の rescue の内側で動く。**書けなくてもハートビート
      # そのものを止めない。
      def touch(jobs:, now: nil)
        record = {
          at: (now || Time.now).getutc.iso8601,
          jobs: jobs,
          version: Package.version,
          pid: Process.pid,
        }
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, record.to_json)
        return record
      end

      # ⚠ **壊れていたら nil。**中身を信じて「健全」と誤答するより、読めないことを
      # 上に返す。
      def read
        return nil unless File.file?(path)
        record = JSON.parse(File.read(path), symbolize_names: true)
        return nil unless record.is_a?(Hash)
        return nil if record[:at].blank?
        return record
      rescue JSON::ParserError, SystemCallError
        return nil
      end

      def jobs
        record = read
        return nil unless record
        return record[:jobs]
      end

      # 最後のハートビートからの経過（秒）。⚠ **読めなければ nil。**
      def age(now = nil)
        record = read
        return nil unless record
        return (now || Time.now) - Time.parse(record[:at])
      rescue ArgumentError
        return nil
      end

      # ⚠ **閾値は設定から出す。**ハートビートの間隔を変えたときに閾値が置き去りに
      # なると、**間隔を延ばした瞬間に監視が誤検知しはじめる**。
      def limit
        seconds = Fugit::Duration.parse(config['/scheduler/heartbeat/interval'].to_s)&.to_sec
        unless seconds&.positive?
          raise Ginseng::ConfigError,
            "heartbeat: bad interval '#{config['/scheduler/heartbeat/interval']}'"
        end
        return seconds * STALE_FACTOR
      end

      # ⚠ **読めない場合も「止まっている」と扱う。**
      def stale?(now = nil)
        seconds = age(now)
        return true unless seconds
        return seconds > limit
      end
    end
  end
end
