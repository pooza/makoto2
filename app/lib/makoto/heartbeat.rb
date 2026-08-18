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
    #
    # ⚠⚠ **これはプロセス内しか守らない。**プロセスをまたぐ側は `LOCK` が守る。
    MUTEX = Mutex.new

    # ⚠⚠ **プロセスをまたいだ read-modify-write を直列化する**（#81 のレビュー指摘）。
    # ⚠ **常駐が一時的に 2 本になりうる** — `Health` が孤児で復旧を叩かせないのは
    # まさにそれが起きるからで、**同じ前提をこちらでも置く**。
    #
    # ⚠ **実測**: 別プロセスと 300 回ずつ更新して、⚠⚠ **600 のはずが 142 しか
    # 数えられなかった**（458 回ぶんの更新が消えた）。
    LOCK_SUFFIX = '.lock'.freeze

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

      # tick が 1 回まわった（#80 の黄 7）。
      #
      # 🔴 **`touch` とは別に持つ。**⚠⚠ **ハートビートは tick とは別の rufus ジョブ**
      # なので、⚠ **tick 側だけが詰まっても `at` は更新され続ける** —
      # **「生きているが投稿していない」を検知するための痕跡が、まさにその状態で
      # 動き続ける**という形だった。
      #
      # ⚠ **記録するのは終わった時刻。**始めた時刻にすると、⚠⚠ **90 秒かかった tick が
      # 「90 秒前に回った」ことになり、詰まりを短く見せる。**
      def record_tick(now: nil)
        return update do |record|
          record.merge(ticked_at: (now || Time.now).getutc.iso8601)
        end
      end

      # 常駐が起き上がったこと。🔴 **初回の tick が終わるまで `tick_stale?` を
      # 鳴らさないための基準**（PR #98 の Codex 指摘）。
      #
      # ⚠⚠ **監視の口は初回 tick より先に開く**（→ `MakotoDaemon#start`）。⚠ **tick が
      # 痕跡を書くのは枠を全部回し終えたあと**で、⚠⚠ **1 回の tick は投稿の再送で
      # 90 秒以上かかりうる** — 🔴 **起き上がっただけで `/healthz` が赤くなる**形だった。
      # ⚠ **前回の稼働が残した古い `ticked_at` も同じ**で、⚠⚠ **落ちて猶予より長く
      # 空くと、戻ってきた瞬間から赤い。**
      #
      # ⚠ **猶予を過ぎても痕跡が無ければ、そこからは本物の詰まり**なので検知は残る。
      def record_start(now: nil)
        return update do |record|
          record.merge(started_at: (now || Time.now).getutc.iso8601)
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
      #
      # ⚠ **守りは 2 段。**`MUTEX` がプロセス内のスレッド（rufus のハートビートと
      # tick）、`flock` がプロセスまたぎ（再起動で一時的に 2 本になる形）。
      def update
        MUTEX.synchronize do
          with_lock do
            record = yield(stored)
            write(record)
            return record
          end
        end
      end

      # ⚠ **鍵は痕跡そのものとは別のファイル。**痕跡は `write` が rename で置き換える
      # ので、⚠⚠ **同じファイルを掴むと、鍵を持ったまま実体が別の inode に入れ替わる。**
      def lock_path
        return path + LOCK_SUFFIX
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

      # 最後に tick が回った時刻。⚠ **一度も無ければ nil**（起動直後・旧い痕跡）。
      def ticked_at
        return parse_time(stored[:ticked_at])
      end

      # 最後に常駐が起き上がった時刻。⚠ **一度も無ければ nil**（→ `record_start`）。
      def started_at
        return parse_time(stored[:started_at])
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

      # tick が止まったとみなすまでの猶予（秒）。⚠ **閾値は設定から出す**（`limit` と
      # 同じ理由）。⚠⚠ **tick の間隔から導かない** — **1 回の tick は投稿の再送で
      # 90 秒以上かかりうる**ので、間隔の倍数にすると誤報する。
      def tick_limit
        seconds = Fugit::Duration.parse(config['/scheduler/tick_stale'].to_s)&.to_sec
        unless seconds&.positive?
          raise Ginseng::ConfigError,
            "heartbeat: bad tick_stale '#{config['/scheduler/tick_stale']}'"
        end
        return seconds
      end

      # tick が回らなくなっているか（#80 の黄 7）。
      #
      # ⚠⚠ **痕跡が無いときも「止まっている」と扱う。**⚠ **常駐は登録の直後に 1 回
      # 叩く**（→ `Scheduler#schedule_posts`）ので、⚠⚠ **生きているのに痕跡が無いのは、
      # tick が一度も回っていないということ。**
      #
      # ⚠⚠ **ただし基準は「最後の tick」と「起き上がった時刻」の新しいほう。**
      # 🔴 **初回の tick は枠を回し終えるまで痕跡を書かない**ので、⚠ **起き上がった
      # 直後を「一度も回っていない」と読むと、起動のたびに赤くなる**（→ `record_start`）。
      # ⚠⚠ **猶予を過ぎればどちらの基準でも赤い**ので、検知そのものは緩まない。
      def tick_stale?(now = nil)
        last = [ticked_at, started_at].compact.max
        return true unless last
        return ((now || Time.now) - last) > tick_limit
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

      private

      # ⚠ **プロセスをまたいだ read-modify-write を直列化する。**⚠⚠ **`Mutex` は
      # プロセス内のスレッドしか守らない**ので、**再起動で一時的に 2 本になる形では
      # 片方の更新が消える**（→ `LOCK_SUFFIX`）。
      def with_lock
        FileUtils.mkdir_p(File.dirname(path))
        File.open(lock_path, File::CREAT | File::RDWR, 0o644) do |lock|
          lock.flock(File::LOCK_EX)
          return yield
        end
      end

      # ⚠⚠ **書き込みは差し替えで行う。**`File.write` は**切り詰めてから書く**ので、
      # ⚠ **その隙に読んだ側は壊れた JSON を掴む。**
      #
      # ⚠⚠ **これは「監視のせいで監視が誤報する」形だった** — 読めない痕跡は
      # `stale?` が true になり、**`makoto status` が 1（復旧させる）を返して monit が
      # 正常な常駐を再起動する。**⚠ **投稿ごとに書くようになって窓が一気に広がった**
      # （1 時間に 1 回 → ライブ当日は 160 回）。⚠ **実測で 2,000 回中 625 回が nil。**
      #
      # ⚠ **rename は同じディレクトリの中なので不可分。**⚠⚠ **読む側は鍵を取らなくて
      # よい**（`makoto status` を待たせない）。
      def write(record)
        temp = "#{path}.#{Process.pid}.tmp"
        File.write(temp, record.to_json)
        File.rename(temp, path)
      ensure
        FileUtils.rm_f(temp)
      end
    end
  end
end
