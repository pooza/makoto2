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

    # 🔴 **`exec` ではない行の目印**（#284 → `PostingJob#notify`）。
    NOTIFY_PHASE = 'notify'.freeze

    # 🔴 **予算を超えて長くかかった枠の目印**（#92 → `PostingJob#warn_slow`）。
    # ⚠⚠ **この行も `post` と `slot` を両方持つ**ので、**捨てないと `exec` 2 回になる**
    # （→ #348・`notify` と同じ形）。
    SLOW_PHASE = 'slow'.freeze

    # ⚠ **`phase` ごとの受け皿**（→ `count_phase`）。⚠⚠ **ここに無い `phase` は捨てる。**
    PHASE_COUNTERS = {NOTIFY_PHASE => :count_notify, SLOW_PHASE => :count_slow}.freeze

    # ⚠ 人が読む順。**赤の判定に関わるものを上に置く。**
    # ⚠ **`slow` は赤に掛からない**ので、赤の判定に関わる 3 つより下に置く（→ #348）。
    SECTIONS = [
      :header, :execs, :posts, :notify, :slow, :http, :heartbeat, :blind
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
      @revisions = Set.new
      lines.each {|line| consume(parse(line))}
    end

    attr_reader :slots, :http, :retries, :heartbeats, :versions, :travel, :lines, :notifies,
      :notify_failures, :notify_misses, :slows, :slow_errors, :revisions

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
    def red?
      return true if anomalous_slots.any? || duplicated_slots.any?
      return true if @notify_failures.positive?
      return http_errors.positive? || failed.positive?
    end

    def http_errors
      return @http.sum {|(_, status), count| status.to_i >= 400 ? count : 0}
    end

    def to_s
      return SECTIONS.filter_map {|section| send(:"format_#{section}")}.join("\n")
    end

    private

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
      return count_heartbeat(entry) if entry[:scheduler] == 'heartbeat'
      return @travel = entry[:time_travel] if entry[:time_travel]
      return nil
    end

    # 🔴 **`phase` を持つ行は `exec` ではない**（#284 / #277 / #348）。⚠ **受け皿のある
    # `phase` はそこへ渡し、無いものは捨てる**（#277 の `quiet` — 黙る日に黙ったことの 1 行）。
    #
    # ⚠⚠ **「捨てた先に受け皿が無い」を作らない**（#348）— 🔴 **`notify` に受け皿を足した
    # ときに `slow` へは足さなかったので、#92 で出した行が丸ごと消えていた。**
    # ⚠ **表に足せば、次に `phase` を増やす人が受け皿の有無を 1 か所で決められる。**
    def count_phase(entry)
      counter = PHASE_COUNTERS[entry[:phase]]
      return counter ? send(counter, entry) : nil
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
    # ⚠ **`red?` には掛けない** — ⚠⚠ **早送りのリハーサルでは実時間が伸びる**ので、
    # **赤にすると毎回鳴る**（#92 は「観測まで」で線を引いている）。
    # 🔴 **だから読む人に見せる**（`#90` の「枠を跨ぐ余裕が構造的にゼロ」が再発したとき、
    # ⚠⚠ **本番の syslog を `grep slow` する人がいる前提にしない**）。
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
      return @http[key]
    end

    # ⚠ **リビジョンも拾う**（#348 / #242）。🔴 **`version` は `0.6.0` のまま何コミットでも
    # 進む**ので、⚠⚠ **見出しが「バージョン 0.6.0」だけだと、リハーサルの途中でデプロイが
    # 挟まっても報告書から分からない**（#242 が消したかった盲点がここに残っていた）。
    def count_heartbeat(entry)
      @heartbeats += 1
      @versions.add(entry[:version].to_s) if entry[:version]
      @revisions.add(entry[:revision].to_s) if entry[:revision]
      return @heartbeats
    end

    def format_header
      out = ["ログ #{@lines} 行 / バージョン #{@versions.to_a.join(', ').presence || '(不明)'}" \
        " / リビジョン #{@revisions.to_a.join(', ').presence || '(不明)'}"]
      # 🔴 **途中でデプロイが挟まった回は、結果を 1 つの版のものとして読めない**（#348 / #242）。
      # ⚠ **赤にはしない**（**リハーサルの終わり際に当てた回もここに出る**）が、⚠⚠ **見出しで言う。**
      out.push("⚠ 途中でリビジョンが変わった（#{@revisions.size} 種）") if @revisions.size > 1
      # ⚠⚠ **騙していたことを必ず出す。**⚠ **後から読む人が「本番のログ」と
      # 取り違えないため**（→ `TimeTravel` が毎ハートビートに `warn` を出すのと同じ理由）。
      out.push(format_travel) if @travel
      out.push('⚠ 日付を騙した痕跡が無い（実時間のログか、水準が warn を落としている）') unless @travel
      return out.join("\n")
    end

    def format_travel
      return "⚠ 日付を騙している: 出発 #{@travel[:start]} / scale #{@travel[:scale]}" \
        " / 投稿先 #{@travel[:mastodon]}"
    end

    def format_execs
      out = ['', "枠あたりの exec 回数（想定 #{EXPECTED_EXECS} 回）"]
      by_name.each do |name, row|
        mark = row[:range] == [EXPECTED_EXECS, EXPECTED_EXECS] ? '  ' : '🔴'
        out.push("#{mark} #{name}: #{row[:slots]} 枠 / exec #{row[:execs]} 回" \
          " / 枠あたり #{format_range(row[:range])}")
      end
      out.push('  （枠が 1 つも無い）') if @slots.empty?
      out.push("🔴 #{anomalous_slots.size} 枠が想定と違う") if anomalous_slots.any?
      return out.join("\n")
    end

    def format_range(range)
      return "#{range.first} 回" if range.first == range.last
      return "#{range.first}〜#{range.last} 回"
    end

    def format_posts
      out = ['', "投稿: 成功 #{posted} 回（status #{unique_posts} 件）" \
        " / 失敗 #{failed} 回 / 沈黙 #{silenced} 回"]
      # ⚠⚠ **赤にした理由を本文にも書く**（#127）。⚠ **終了コードだけが赤で、読んでも
      # どこが赤か分からない形にしない。**
      out.push("🔴 #{failed} 回の投稿が落ちた") if failed.positive?
      # 🔴 **500 が止まった世界で現れる壊れ方。**⚠ 回数の異常とは別に名指しする。
      duplicated_slots.each do |(name, slot), row|
        out.push("🔴 #{name} #{slot} が #{row[:posts].uniq.size} 件の status を作った（重複投稿）")
      end
      return out.join("\n")
    end

    # ⚠ **履歴の通知**（#284）。🔴 **1 行も無いのが普通**（`posted` を持つのは曲紹介だけ）
    # なので、**出ていないこと自体は異常ではない。**
    def format_notify
      return nil if @notifies.zero?
      out = ['', "履歴の通知: #{@notifies} 回 / 失敗 #{@notify_failures} 回"]
      # ⚠⚠ **赤にした理由を本文にも書く**（#127 と同じ）。
      out.push("🔴 #{@notify_failures} 回の通知が落ちた（投稿は出ているが履歴が伸びていない）") \
        if @notify_failures.positive?
      # 🔴 **落ちた回とは別に数える**（#348）。⚠⚠ **こちらは例外にならない** —
      # **`posted` が `nil` を返しただけ**なので、**ログの上では成功した枠と同じ形に見える。**
      # ⚠ **赤にしないのは、履歴を切ってあれば毎枠出るから**（→ `count_notify`）。
      out.push("⚠ #{@notify_misses} 回が履歴を伸ばさなかった（recorded:false）") if @notify_misses.positive?
      return out.join("\n")
    end

    # 🔴 **予算を超えて長くかかった枠**（#348 / #92）。⚠ **1 行も無いのが普通**なので、
    # **無ければ節そのものを出さない**（`format_notify` と同じ扱い）。
    def format_slow
      return nil if @slows.empty? && @slow_errors.zero?
      out = ['', "予算を超えた枠: #{@slows.size} 回"]
      out += @slows.map do |row|
        "⚠ #{row[:post]} #{row[:slot]}: #{row[:seconds]} 秒（予算 #{row[:budget]} 秒）"
      end
      out.push("⚠ 計測そのものが #{@slow_errors} 回落ちた") if @slow_errors.positive?
      # ⚠⚠ **早送りでは実時間が伸びる**ので、🔴 **この節が出ること自体は異常ではない**
      # （→ #92 / #90）。⚠ **読む人が「本番でも遅い」と取り違えないため、毎回書く。**
      out.push('⚠ 早送り中は実時間が伸びるので、この節は赤ではない（→ #90 / #92）') if scaled?
      return out.join("\n")
    end

    def format_http
      out = ['', 'HTTP']
      sorted = @http.sort_by {|(method, status), _| [method.to_s, status.to_i]}
      sorted.each do |(method, status), count|
        mark = status.to_i >= 400 ? '🔴' : '  '
        out.push("#{mark} #{method} #{status}: #{count} 回")
      end
      out.push('  （1 本も無い）') if @http.empty?
      out.push("⚠ 再送 #{@retries} 回") if @retries.positive?
      return out.join("\n")
    end

    def format_heartbeat
      return "\nハートビート: #{@heartbeats} 回"
    end

    # ⚠⚠ **読めていないものを毎回書く。**🔴 **「集計が緑だから大丈夫」と読ませない。**
    def format_blind
      out = ['', '⚠ この集計では読めないもの']
      out.push('- 沈黙した枠の exec 回数（本文が無いときの 1 行は `debug` → #114）') if silenced.zero?
      out.push('- 実時間の経過に依存するもの（メモリ・接続の寿命・ログのローテート）')
      # 🔴 **数えているが赤にしないものを名指しする**（#348）。⚠⚠ **「集計が緑 ＝ 何も
      # 起きていない」と読ませない** — ⚠ **どちらも上の節に出ているので、見落とすのは
      # 終了コードだけを見たとき。**
      out.push('- 予算を超えた枠と recorded:false は赤にしない（履歴を切った構成では毎枠出る）')
      out.push('- 外部が実時間で持つ制限（Mastodon のレート制限窓）')
      out.push('- 投稿が枠を跨ぐか（早送りでは見かけ上 scale 倍かかる → #90 / #92）') if scaled?
      return out.join("\n")
    end

    def scaled?
      return @travel.present? && @travel[:scale].to_i > 1
    end
  end
end
