module Makoto
  # リハーサルの結果を集める側（#110）。⚠ **仕掛け（`TimeTravel`）とは分ける。**
  #
  # ⚠⚠ **リハーサルは結合テストに相当する**（→ docs/CLAUDE.md リリース手順 4）ので、
  # ⚠ **毎リリース「何が起きたか」を同じ形で読めること**が要る。
  #
  # ## 🔴 なぜログを後から読む形にしたか
  #
  # ⚠⚠ **計測のためのコードを投稿の経路に足さない。**⚠ **常駐に数え上げを持たせると、
  # それ自体が本番と違う挙動**になり、**「日付以外は全く同じ」が崩れる。**
  #
  # ⚠ **ログは既に必要な粒度で出ている**（`{"post":…,"slot":…,"status_id":…}` /
  # `{"method":…,"status":…}`）。🔴 **同じ道具が 11/4 当日そのものにも使える** —
  # **本番のログを流し込めば、当日の集計がリハーサルと同じ表で出る。**
  #
  # ## 🔴 いちばん重要なのは「枠あたりの exec 回数」
  #
  # ⚠⚠ **#109 は 500 が出たから気づいた。**🔴 **500 が出なくなったら（＝冪等キーが
  # 効いて畳まれるか、逆に重複投稿するようになったら）静かに壊れる。**
  # ⚠ **回数そのものを毎回数える**（→ docs のリリース手順 4）。
  #
  # ⚠ **数え方**: `post` と `slot` の両方を持つ行が `PostingJob#exec` 1 回に対応する
  # （成功は `status_id`、失敗は `error`、本文が無ければ `message`）。
  # ⚠⚠ **`{"scheduler":"register","post":…}` は `slot` を持たない**ので混ざらない。
  #
  # 🔴 **`phase` を持つ行は `exec` ではない**（#284・Codex の P2）。⚠⚠ **履歴の通知は
  # 投稿が成功した**後**に出る行**で、**`post` と `slot` を両方持つ** — ⚠ **素で数えると
  # **1 枠の exec が 2 回**になり、**成功した回が `anomalous_slots` に落ちて赤になる。**
  # 🔴 **失敗の側も同じ** — **`error` を持つので「投稿が落ちた」1 回として数えられるが、
  # 落ちたのは履歴の通知で、投稿そのものは出ている。**
  #
  # ## ⚠⚠ 数えられないもの
  #
  # 🔴 **沈黙した枠の exec 回数は数えられない。**⚠ **本文が無いときの 1 行は
  # `debug`** で、⚠⚠ **既定の水準（`info`）では出ない**（→ #114）。**#114 が入るまで、
  # 「出るべき日に出なかった枠」はこの集計にも現れない。**
  class RehearsalReport
    include Package

    # 枠あたりの想定 exec 回数。⚠ **これ以外は赤にする。**
    EXPECTED_EXECS = 1

    # ⚠ **`revision` を持たないハートビートの印**（→ `count_heartbeat`・Codex の P2）。
    UNKNOWN_REVISION = '(不明)'.freeze

    # ⚠ **`phase` ごとの受け皿**（→ `count_phase`）。⚠⚠ **ここに無い `phase` は捨てる**
    # （#277 の `quiet` — 黙る日に黙ったことの 1 行）。
    #
    # - `notify` — **履歴の通知**（#284 → `PostingJob#notify`）
    # - `slow` — **予算を超えて長くかかった枠**（#92 → `PostingJob#warn_slow`）
    #
    # 🔴 **どちらも `post` と `slot` を両方持つ**ので、⚠⚠ **受け皿に入れずに数えると
    # `exec` 2 回の偽の赤になる**（→ #348 / #284）。
    PHASE_COUNTERS = {'notify' => :count_notify, 'slow' => :count_slow}.freeze

    # ⚠ **受け皿に入らなかった `error` 行の名札に使う欄**（→ `count_unclassified`）。
    # ⚠ **前から 2 つまで**（`scheduler:tick post:song` のように、どこで落ちたかが分かる粒度）。
    LABEL_KEYS = [
      :daemon, :scheduler, :track, :mastodon, :sentry, :time_travel, :post, :config
    ].freeze

    # @param lines [Enumerable<String>] ログの行。⚠ **JSON でない行は捨てる**
    #   （例外のバックトレースは `  /path:12:in …` の素の行で出る）
    def initialize(lines)
      @slots = {}
      @http = {}
      @retries = 0
      @heartbeats = 0
      @versions = Set.new
      @travel = nil
      @lines = 0
      @notifies = 0
      @notify_failures = 0
      @notify_misses = 0
      @slows = []
      @slow_errors = 0
      @heartbeat_errors = 0
      @revisions = Set.new
      @http_seconds = {}
      @proxy_added = []
      @proxy_skipped = 0
      @rejects = []
      @unclassified = Hash.new(0)
      lines.each {|line| consume(parse(line))}
    end

    attr_reader :slots, :http, :retries, :heartbeats, :versions, :travel, :lines, :notifies,
      :notify_failures, :notify_misses, :slows, :slow_errors, :revisions, :heartbeat_errors,
      :proxy_skipped, :rejects, :unclassified

    # 🔴 **枠あたりの exec が 1 でないもの。**⚠ **#109 の回帰はここに出る。**
    def anomalous_slots
      return @slots.reject {|_, slot| slot[:execs] == EXPECTED_EXECS}
    end

    # 🔴 **1 つの枠から 2 つ以上の status_id が出たもの ＝ 重複投稿。**
    # ⚠⚠ **これは 500 が止まったときに現れる壊れ方**なので、回数とは別に数える。
    #
    # ⚠ **`uniq` を通す。**⚠⚠ **冪等キーが効いて同じ status_id が返った場合は
    # 重複投稿ではない**（Mastodon 側が畳んでいる ＝ 設計どおり）。**回数の異常は
    # `anomalous_slots` の側が拾う。**
    def duplicated_slots
      return @slots.select {|_, slot| slot[:posts].uniq.size > 1}
    end

    # 枠名ごとの内訳。⚠ 順は現れた順（`live-eve` → `live-open` → `live` → …）。
    def by_name
      return @slots.group_by {|key, _| key.first}.transform_values do |entries|
        execs = entries.map {|_, slot| slot[:execs]}
        {
          slots: entries.size,
          execs: execs.sum,
          range: execs.minmax,
          posts: entries.sum {|_, slot| slot[:posts].size},
          failures: entries.sum {|_, slot| slot[:failures]},
          silences: entries.sum {|_, slot| slot[:silences]},
        }
      end
    end

    def posted
      return @slots.sum {|_, slot| slot[:posts].size}
    end

    def failed
      return @slots.sum {|_, slot| slot[:failures]}
    end

    def silenced
      return @slots.sum {|_, slot| slot[:silences]}
    end

    # ⚠ **冪等キーが効いていれば、同じ枠の 2 回目以降は同じ status_id になる。**
    # ⚠⚠ **実測ではそうならなかった**（#109）ので、**延べと実数の両方を出す。**
    def unique_posts
      return @slots.sum {|_, slot| slot[:posts].uniq.size}
    end

    # 🔴 **赤が 1 つでもあるか。**⚠ 呼ぶ側の終了コードに使う。
    #
    # ⚠⚠ **落ちた枠も赤**（#127・Codex の指摘）。🔴 **応答を伴わない失敗**（`source` の
    # 例外・名前解決・タイムアウト）は **`{"post":…,"slot":…,"error":…}` の 1 行しか
    # 残さない**ので、⚠ **`http_errors` にも `anomalous_slots`（exec は 1 回のまま）にも
    # `duplicated_slots`（`status_id` が無い）にも掛からなかった。**
    # ⚠⚠ **枠が落ちているのに終了コード 0 で通っていた** — **毎リリースの結合テストの
    # 合否そのもの**（→ docs/CLAUDE.md リリース手順 4）なので、ここが緑になるのは困る。
    #
    # ⚠ **`silenced`（本文が無い）は赤にしない。**⚠⚠ **「今日は投稿しない」であって
    # 失敗ではない**（→ `PostingJob#exec`）。**出るべき日に出なかったことを言えるのは
    # 中身を知っている側だけ**（→ #114 が入るまでこの集計には現れない）。
    # 🔴 **痕跡の書き込みが落ちた回も赤**（#362・2026-09-19 オーナー判断）。⚠⚠ **痕跡は
    # `/healthz` が読むもの**（→ `Health`）なので、**書けていない間は死活監視が古い値を
    # 見ている ＝ 監視が盲目。**⚠ **`Heartbeat` が fail-open で常駐を止めないこととは両立する**
    # — 🔴 **止めない設計と、リハーサルの合否は別。**
    #
    # 🔴 **予算を超えた枠も赤**（#368・同じ判断。⚠ **#92 が「観測まで」で引いた線を引き直した**）。
    # ⚠⚠ **打ち切らない判断はそのまま**（`Timeout.timeout` は二重投稿の入口 → #92）で、
    # **「合否に数えない」線だけを動かした** — ⚠ **`warn_slow` は monotonic で測り予算も実秒**
    # なので、🔴 **この行が出たら早送りでも実時間で本当に予算を超えている。**
    # ⚠ **計測そのものが落ちた回（`@slow_errors`）も倒す** — **測れていない窓は、この集計が
    # 嘘をつきうる窓**（#362 と同じ理屈）。
    #
    # 🔴 **見ていない回も赤**（#416・`0.7` のリリース前レビュー）。⚠⚠ **枠が 0 かハートビートが 0
    # なら、入力を間違えたか常駐が起きていない** — ⚠ **「何も落ちていない」ではなく「何も見ていない」。**
    # 🔴 **登録を見送った投稿（#350）と、受け皿に入らなかった `error` 行も赤**（→ `count_unclassified`）。
    def red?
      return true if unseen?
      return true if anomalous_slots.any? || duplicated_slots.any?
      return true if @notify_failures.positive? || @heartbeat_errors.positive?
      return true if @slows.any? || @slow_errors.positive?
      return http_errors.positive? || failed.positive?
    end

    # 🔴 **何も見ていない**（#416）。⚠ **`--since` の打ち間違い・unit 名の誤り・起動で落ちた回。**
    def blank?
      return @slots.empty? || @heartbeats.zero?
    end

    # 🔴 **見えているはずのものが見えていない**（#416）— 何も見ていない回・登録を見送った投稿・
    # 受け皿に入らなかった `error` 行。
    def unseen?
      return blank? || @rejects.any? || @unclassified.any?
    end

    def http_errors
      return @http.sum {|(_, status), count| status.to_i >= 400 ? count : 0}
    end

    # 🔴 **メソッドごとの 1 本あたりの所要**（#201）。⚠ **元は `ginseng-core` の `HTTP#log` が
    # 入れる `seconds`**（`(Time.now - start).round(3)`）。
    #
    # 🔴🔴 **この秒は早送りの回では「見かけ」。**⚠⚠ **始点も差も `Time.now` で取る**ので、
    # **`Timecop.scale(n)` の下では実時間の n 倍で出る** — ⚠ **`Timecop.thread_safe` の既定は
    # `false`** なので、**投稿を投げる別スレッドにも効く**（2026-09-23 に実測。**scale 10 で
    # 実時間 0.3 秒の待ちが、別スレッドの `Time.now` では 3.003 秒**）。
    # ⚠ **`PostingJob#warn_slow` の `seconds` とは別物**（🔴 **あちらは `CLOCK_MONOTONIC` ＝
    # 実時間**なので割り引けない → `count_slow`）。**同じ名前で単位が違う。**
    # 🔴 **実時間へ戻すのは読ませる側の仕事**（→ `RehearsalPresenter#format_durations`）。
    #
    # ⚠ **応答が返った行だけが入る。**⚠⚠ **落ちた試行の行は `seconds` を持たない**
    # （`log_retry_error` は `start` を素のまま出す）ので、🔴 **再送で食った時間はここに現れない。**
    #
    # ⚠ **4xx / 5xx も混ぜる**（🔴 **手で `grep POST` した #201 の数え方に合わせる** — ⚠⚠ **落ちた
    # 応答は速く返るので、混ぜると中央値が下がる**。**ただし応答が 400 台なら `red?` が先に倒す**）。
    def http_durations
      return @http_seconds.transform_values do |seconds|
        sorted = seconds.sort
        {count: sorted.size, min: sorted.first, median: median(sorted), max: sorted.last}
      end
    end

    # ⚠ **モロヘイヤが足した字数の分布**（#351）。
    #
    # 🔴 **`/mastodon/proxy_reserve`（100 字）はここの max で引く。**⚠⚠ **見積もりのままだと、
    # 辞書に多く当たる原稿で上限を超え、422 でその枠が消える**（`PERMANENT_STATUSES` なので
    # 再送しない）。⚠ **リハーサル 1 回で 162 本ぶん採れる**ので、**1 回測って終わりにならない。**
    #
    # ⚠ **迂回した回は入らない**（🔴 **モロヘイヤが何もしていない**）。
    def proxy_added
      return nil if @proxy_added.empty?
      sorted = @proxy_added.sort
      return {count: sorted.size, min: sorted.first, median: median(sorted), max: sorted.last}
    end

    # ⚠ **本文の組み立ては `RehearsalPresenter`**（🔴 **数える側と分けた** — 2026-09-19）。
    def to_s
      return RehearsalPresenter.new(self).to_s
    end

    private

    # ⚠ **偶数本は中央 2 つの平均。**🔴 **ログ自身が 3 桁で丸めている**ので、同じ桁で返す。
    #
    # 🔴 **`2.0` で割る**（#351・Codex の P2）。⚠⚠ **`proxy_added` は整数**なので、**`/ 2` だと
    # 整数除算で切り捨てる**（**12 と 13 の中央が 12 になっていた**）。⚠ **所要（Float）の側は
    # どちらでも同じ**なので、**整数の側に合わせる。**
    def median(sorted)
      half = sorted.size / 2
      return sorted[half] if sorted.size.odd?
      return ((sorted[half - 1] + sorted[half]) / 2.0).round(3)
    end

    def parse(line)
      return JSON.parse(line.to_s, symbolize_names: true)
    rescue JSON::ParserError
      return nil
    end

    def consume(entry)
      return nil unless entry.is_a?(Hash)
      @lines += 1
      # 🔴 **`count_slot` より先に見る**（#284）。⚠⚠ **この行も `post` と `slot` を
      # 両方持つ**ので、**後ろに置くと `exec` として数えられてしまう。**
      return count_phase(entry) if entry[:phase]
      return count_slot(entry) if entry[:post] && entry[:slot]
      return count_http(entry) if entry[:method] && entry[:url]
      return count_post(entry) if entry[:mastodon] == 'post'
      return consume_rest(entry)
    end

    # ⚠ **`consume` の続き**（`Metrics` の上限で割った）。🔴 **最後は必ず `count_unclassified`。**
    def consume_rest(entry)
      return count_heartbeat(entry) if entry[:scheduler] == 'heartbeat'
      # ⚠ **要約（Hash）だけを拾う**（#417）。🔴 **弾いたときの `{"time_travel":"refused",…}` は
      # 文字列**で、**拾うと見出しが要約として読もうとして落ちる。**
      return @travel = entry[:time_travel] if entry[:time_travel].is_a?(Hash)
      return count_reject(entry) if entry[:scheduler] == 'reject'
      return count_unclassified(entry)
    end

    # 🔴 **起動時の検査で登録を見送った投稿**（#350 → `Scheduler#reject`）。⚠⚠ **`slot` を
    # 持たないので、受け皿が無かった頃は捨てていた** — **`live` の 160 枠が丸ごと無くても緑だった**（#416）。
    def count_reject(entry)
      return @rejects.push(entry.slice(:post, :reason))
    end

    # 🔴🔴 **どの受け皿にも入らなかった `error` 行を数える**（#416）。⚠⚠ **この集計は行の種類を
    # 欄の有無だけで判別する**ので、**ログに行の形を足すと、受け皿が無いまま黙って捨てられる**
    # （#284 / #348 / #351 に続いて 4 回目）。⚠ **最後にここで拾えば、形を増やしても黙らない**
    # — 🔴 **赤になって、報告書に名札が出る。**
    #
    # ⚠ **`errors` も拾う**（`{"config":"invalid","errors":[…]}` → `MakotoDaemon`）。
    # ⚠⚠ **warn の行も混ざる**（`verify_credentials` の「確かめられなかった」など）— 🔴 **ログの本文に
    # 水準の欄は無い**（重さは journal の `PRIORITY` 側）ので**分けられない。**⚠ **リハーサル中に
    # 出たなら、どちらにしても読む価値がある。**
    def count_unclassified(entry)
      return nil unless entry[:error] || entry[:errors]
      label = LABEL_KEYS.filter_map {|key| "#{key}:#{entry[key]}" if entry[key].is_a?(String)}
      return @unclassified[label.first(2).join(' ').presence || '(名札なし)'] += 1
    end

    # 🔴 **`phase` を持つ行は `exec` ではない**（#284 / #277 / #348）。⚠ **受け皿のある
    # `phase` はそこへ渡し、無いものは捨てる**（#277 の `quiet` — 黙る日に黙ったことの 1 行）。
    #
    # ⚠⚠ **「捨てた先に受け皿が無い」を作らない**（#348）— 🔴 **`notify` に受け皿を足した
    # ときに `slow` へは足さなかったので、#92 で出した行が丸ごと消えていた。**
    # ⚠ **表に足せば、次に `phase` を増やす人が受け皿の有無を 1 か所で決められる。**
    def count_phase(entry)
      counter = PHASE_COUNTERS[entry[:phase]]
      # ⚠ **受け皿の無い `phase` でも、`error` を持つなら黙って捨てない**（#416）。
      return counter ? send(counter, entry) : count_unclassified(entry)
    end

    # ⚠ **1 行 = `exec` 1 回。**結末で内訳を分ける（成功 / 失敗 / 沈黙）。
    def count_slot(entry)
      slot = (@slots[[entry[:post], entry[:slot]]] ||= {
        execs: 0, posts: [], failures: 0, silences: 0
      })
      slot[:execs] += 1
      slot[:posts].push(entry[:status_id]) if entry[:status_id]
      slot[:failures] += 1 if entry[:error]
      slot[:silences] += 1 if entry[:message]
      return slot
    end

    # 🔴 **履歴の通知は投稿ではない**（#284）。⚠ **`exec` にも投稿の成否にも数えない。**
    #
    # ⚠⚠ **ただし落ちたことは赤のまま残す。**🔴 **この行が無かった頃は `post` と `slot` と
    # `error` を持つ 1 行として `failed` に数えられており、`red?` に掛かっていた** —
    # ⚠ **区別を足したついでに見逃す形にしない**（**投稿は出たのに履歴が伸びていない** ＝
    # **#41 の重複回避が切れている**）。
    # 🔴 **`recorded: false` を数える**（#348）。⚠⚠ **これが「投稿は出たのに履歴が
    # 伸びていない」** ＝ **#41 の重複回避が無言で切れた状態**（→ `PostingJob#notify`）。
    # ⚠ **数えなかった頃は、全部 `true` だった回と出力が 1 文字も変わらなかった。**
    #
    # 🔴 **`red?` には掛けない。**⚠⚠ **履歴を切ってあれば毎枠出る**（**`TrackLottery#record`
    # は `@history` が無ければ `nil`** ＝ **`recorded: false`**）ので、⚠ **赤にすると
    # 履歴を持たない構成のリハーサルが毎回落ちる**（→ #284 で決めた線・`test/rehearsal_report.rb`
    # の `test_a_notify_miss_is_not_a_failure` が固定している）。
    def count_notify(entry)
      @notifies += 1
      @notify_failures += 1 if entry[:error]
      # ⚠ **キーが無い行と `false` を混ぜない**（`!recorded.nil?` の結果なので真偽値で来る）。
      @notify_misses += 1 if entry[:recorded] == false
      return @notifies
    end

    # 🔴 **予算を超えた枠を覚える**（#348 / #92）。
    #
    # ⚠ **`red?` には掛けない** — 🔴 **#92 が「観測まで」で線を引いた**（**打ち切らない**）ため。
    # ⚠ **代わりに読む人に見せる**（**#90 の「枠を跨ぐ余裕が構造的にゼロ」が再発したときに、
    # ⚠⚠ 本番の syslog を `grep slow` する人がいる前提にしない**）。
    #
    # 🔴 **「早送りだから鳴るので赤にしない」ではない**（Codex の P2・3 巡目）— ⚠⚠ **`warn_slow` は
    # `CLOCK_MONOTONIC` で測り、予算も実秒**なので、**`Timecop.scale` が動かすのは
    # `Time.now`（予定の側）だけで、この数字は割り引けない。**⚠ **実地でも 8 回目のリハーサル
    # （scale 10・予算 92 秒）で 0 件。**🔴 **この節が出たら、実時間で本当に予算を超えている** —
    # ⚠ **赤にするかはオーナー判断**（→ #92 の線を引き直す話）。
    #
    # ⚠ **計測そのものが落ちた行は別に数える**（`warn_slow` の `rescue` は `slot` を
    # 持たない `{post:, phase: 'slow', error:}`）。
    def count_slow(entry)
      return @slow_errors += 1 if entry[:error]
      return @slows.push(entry.slice(:post, :slot, :seconds, :budget))
    end

    # ⚠ **応答が返った行と、落ちた試行の行を分ける。**⚠⚠ **後者は `count` を持ち、
    # 再送の回数そのもの**なので、`status` ごとの内訳には混ぜない。
    def count_http(entry)
      return @retries += 1 if entry[:count]
      key = [entry[:method], entry[:status]]
      @http[key] = @http.fetch(key, 0) + 1
      # ⚠ **所要はメソッド単位で貯める**（→ `http_durations`）。🔴 **status では割らない** —
      # ⚠⚠ **#201 が読みたいのは「投稿 1 本にどれだけかかるか」**で、**結末ごとの分布ではない。**
      (@http_seconds[entry[:method]] ||= []).push(entry[:seconds].to_f) if entry[:seconds]
      return @http[key]
    end

    # ⚠ **リビジョンも拾う**（#348 / #242）。🔴 **`version` は `0.6.0` のまま何コミットでも
    # 進む**ので、⚠⚠ **見出しが「バージョン 0.6.0」だけだと、リハーサルの途中でデプロイが
    # 挟まっても報告書から分からない**（#242 が消したかった盲点がここに残っていた）。
    # 🔴 **モロヘイヤが足した分を貯める**（#351）。⚠ **持たない行は捨てる**
    # （迂回した回・`content` を持たない応答・`unexpected response shape` の警告）。
    #
    # 🔴🔴 **成功した投稿の行だけ数える**（Codex の P2）。⚠⚠ **`status_id` を持たない
    # `mastodon: 'post'` は警告のほう** — ⚠ **同じ欄名を診断に出した日に、捨てた値が
    # 分布へ入る。**🔴 **負も数えない** — ⚠⚠ **モロヘイヤが字数を減らすことは無い**ので、
    # **負は「応答から本文を戻しきれていない」値。**
    # ⚠ **出す側でも欄名を分けているが、数える側だけでも成り立つようにしておく。**
    #
    # 🔴 **測れなかった投稿は数えておく**（Codex の P2）。⚠⚠ **1 本でも測れていなければ、
    # 分布に最大が居るとは限らない** — ⚠ **「全部測れなかった」だけを言うと、部分的な
    # 取りこぼしが成功したように見える。**
    # ⚠ **数えるのは成功の行 1 本につき 1 回**（🔴 **負の警告の行は `status_id` を持たない**ので、
    # **同じ投稿を 2 回数えない**）。
    #
    # 🔴 **`status_id` の無い行は受け皿へ回す**（#419 の Codex の P2）。⚠⚠ **`proxy_added` の計測が
    # 落ちた行（`{"mastodon":"post","message":"proxy_added failed","error":…}`）もここへ来る**ので、
    # **素で捨てると `count_unclassified` まで届かない** — ⚠ **`error` を持たない警告は向こうで捨てる。**
    def count_post(entry)
      return count_unclassified(entry) unless entry[:status_id]
      added = entry[:proxy_added]
      return @proxy_skipped += 1 unless added.is_a?(Numeric)
      return @proxy_skipped += 1 if added.negative?
      return @proxy_added.push(added.to_i)
    end

    def count_heartbeat(entry)
      # 🔴 **痕跡の書き込みが落ちた行は別に数える**（#362）。⚠ **`Scheduler` の `rescue` が
      # `{scheduler: 'heartbeat', error:}` を出す**（`schedule_heartbeat`）ので、⚠⚠ **1 回の
      # tick が 2 行出る** — **素で数えると落ちた tick だけ「2 回」になる**（報告書は「回」と書く）。
      # ⚠ **版も持たない**ので、**`(不明)` を足すと 1 つの版で通した回が「途中で変わった」に化ける。**
      return @heartbeat_errors += 1 if entry[:error]
      @heartbeats += 1
      @versions.add(entry[:version].to_s) if entry[:version]
      # 🔴 **持たない行も 1 種として覚える**（Codex の P2）。⚠⚠ **`if` で捨てると、
      # 混ざったログで「全部この 1 つのリビジョン」に見え、警告も出ない** — ⚠ **#242 より
      # 前の版や、git 以外から置いた箱のハートビートは `revision` を持たない。**
      @revisions.add(entry[:revision].presence || UNKNOWN_REVISION)
      return @heartbeats
    end
  end
end
