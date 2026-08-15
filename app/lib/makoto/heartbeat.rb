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
  #
  # ## 投稿の結末（#78）
  #
  # ⚠⚠ **「常駐が生きている」と「投稿が実際に出ている」は別物。**`jobs` は**起動時に
  # 決まる登録の本数**なので、**160 枠すべてが失敗しても `jobs: 5` のまま**だった。
  # そこで**枠の結末を 3 つに分けて**、失敗の側だけを数える。
  #
  # | 枠の結末 | 記録 | 理由 |
  # | --- | --- | --- |
  # | 投稿できた | `posted_at` を更新し `failures` を 0 に戻す | — |
  # | ⚠ **本文が無い** | **何も記録しない（中立）** | **原稿が無い日は投稿しないのが正常。**⚠⚠ **`source` は正しく動いている** |
  # | ⚠ **`source` が落ちた／投稿が失敗した** | `failed_at` を更新し `failures` を 1 つ進める | — |
  #
  # ⚠⚠ **「本文が無い」を中立に置くのが肝。**これを失敗に数えると、**投稿すべき原稿が
  # 無いだけの日**（MAKOTO は 8/15〜10/31 の 2 か月半がこれ）が延々と赤くなる。逆に
  # 成功に数えると、⚠ **#77 の「設定を消すと枠の中で例外が上がる」形が中立に紛れる**
  # （その経路も本文が nil になるため）。**だから `source` の失敗と空の本文を、
  # `PostingJob` の側で分けている。**
  class Heartbeat
    include Package

    # ハートビートが止まったとみなすまでの倍率。⚠ **1 回の取りこぼしでは騒がない。**
    STALE_FACTOR = 3

    # ⚠ **痕跡の更新は読んで書き直す形。**`Scheduler` のハートビートと `PostingJob` の
    # 結末は**別のスレッド**（rufus）から来るので、**素に書くと片方の更新が消える。**
    MUTEX = Mutex.new

    # 二重に数えないために覚えておく枠の数。
    #
    # ⚠⚠ **同じ枠が 2 回実行されうる。**`Scheduler` は**登録直後に初回 tick を叩いて
    # から `every` で回す**ので、⚠ **拾う幅（既定 10 秒）の内側で 2 回来ることがある**。
    # **再起動が挟まれば毎回そうなる。**⚠⚠ **成功は冪等キーで Mastodon 側が畳むのに、
    # 失敗だけ畳まれず、落ちた枠 1 つで閾値を 2 つ消費していた**（#81 の指摘・実測）。
    #
    # ⚠ **覚える数を絞るのは、痕跡を無限に太らせないため。**同じ枠が重なるのは拾う幅
    # （数秒）の内側だけなので、⚠⚠ **その間に来うる枠の数＝登録されたジョブの本数を
    # 上回っていれば足りる**（いまは 5 本）。
    COUNTED_SLOTS = 32

    class << self
      # ⚠ **テストは別のファイルに落とす。**`Environment.db` と同じ理由で、稼働中の
      # 痕跡をテストが書き換えると `makoto status` が嘘をつく。
      def path
        name = Environment.test? ? 'heartbeat_test.json' : 'heartbeat.json'
        return File.join(Environment.dir, 'tmp/run', name)
      end

      # ⚠ **呼ぶ側（`Scheduler`）の rescue の内側で動く。**書けなくてもハートビート
      # そのものを止めない。
      #
      # ⚠⚠ **投稿の結末（`posted_at` / `failed_at` / `failures`）を消さない。**ここは
      # 1 時間ごとに動くので、素に書き直すと**枠の結末が毎時ぜんぶ消える。**
      def touch(jobs:, now: nil)
        return update do |record|
          record.merge(
            at: (now || Time.now).getutc.iso8601,
            jobs: jobs,
            version: Package.version,
            pid: Process.pid,
          )
        end
      end

      # 枠が 1 つ投稿できた。⚠ **失敗の数を 0 に戻す。**
      def record_success(now: nil)
        return update do |record|
          record.merge(posted_at: (now || Time.now).getutc.iso8601, failures: 0, slots: [])
        end
      end

      # 枠が 1 つ落ちた（`source` の例外・投稿の失敗）。
      #
      # ⚠ **数えるのは「最後の成功からの連続」。**⚠⚠ **1 本の取りこぼしで騒がない**
      # のはハートビートの `STALE_FACTOR` と同じ考え方だが、⚠ **こちらは時間ではなく
      # 本数で見る** — MAKOTO は平常日に数本しか投稿しないので、**時間で見ると
      # ライブ当日（3 分間隔）と平常日で意味が変わってしまう。**
      #
      # @param slot [String] 枠の識別子（`PostingJob#idempotency_key`）。
      #   ⚠⚠ **同じ枠を 2 度数えない**（→ `COUNTED_SLOTS`）。⚠ **省くと毎回数える。**
      def record_failure(slot: nil, now: nil)
        return update do |record|
          time = (now || Time.now).getutc.iso8601
          counted = Array(record[:slots])
          # ⚠ 既に数えた枠なら、時刻だけ進めて数は据え置く。
          next record.merge(failed_at: time) if slot && counted.include?(slot)
          record.merge(
            failed_at: time,
            failures: record[:failures].to_i + 1,
            slots: slot ? counted.push(slot).last(COUNTED_SLOTS) : counted,
          )
        end
      end

      # ⚠ **読んで書き直す。**⚠⚠ **`read` ではなく `stored` から読む** — 時刻の欠けた
      # 痕跡は `read` が nil にするので、そちらを使うと**書き直すたびに投稿の結末が
      # 消える。**
      def update
        MUTEX.synchronize do
          record = yield(stored)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, record.to_json)
          return record
        end
      end

      # 保存されているものをそのまま。⚠ **`read` と違って `at` の有無を問わない。**
      # ⚠⚠ **読めないときも `{}` で、nil を返さない** — これを使うのは「消さずに
      # 引き継ぐ」ためなので、読めないことと空であることを区別する意味が無い。
      def stored
        return {} unless File.file?(path)
        record = JSON.parse(File.read(path), symbolize_names: true)
        return record.is_a?(Hash) ? record : {}
      rescue JSON::ParserError, SystemCallError
        return {}
      end

      # ⚠ **壊れていたら nil。**中身を信じて「健全」と誤答するより、読めないことを
      # 上に返す。⚠⚠ **時刻の欠けた痕跡も読めないものとして扱う**（経過が出せない）。
      def read
        record = stored
        return nil if record[:at].blank?
        return record
      end

      # 最後の成功からの、連続した失敗の数。⚠ **読めなければ 0**（→ `Health`）。
      def failures
        return stored[:failures].to_i
      end

      # 最後に投稿できた時刻／最後に落ちた時刻。⚠ **一度も無ければ nil。**
      def posted_at
        return parse_time(stored[:posted_at])
      end

      def failed_at
        return parse_time(stored[:failed_at])
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

      # ⚠ **壊れた時刻は nil。**痕跡は観測のためのものなので、読めないことを上に返す。
      def parse_time(value)
        return nil if value.blank?
        return Time.parse(value)
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

      # 何本続けて落ちたら異常とみなすか。⚠ **閾値は設定から出す**（`limit` と同じ理由）。
      #
      # ⚠⚠ **欠けたら例外にする。**`optional_config` で既定値に逃がすと、⚠ **設定を
      # 消しただけで検知が静かに緩む**（#77 の裏返し）。**schema で必須にしてあるので
      # `rake config:lint` が先に止める。**
      def failure_limit
        count = config['/scheduler/posting/failure_limit']
        unless count.is_a?(Integer) && count.positive?
          raise Ginseng::ConfigError, "posting: bad failure_limit '#{count}'"
        end
        return count
      end

      # ⚠ **投稿が続けて落ちているか。**⚠⚠ **本文の無い枠は数に入っていない**ので、
      # **原稿が無いだけの日は何本過ぎても false**（→ このクラスの冒頭の表）。
      def failing?
        return failures >= failure_limit
      end
    end
  end
end
