module Makoto
  # リハーサルの報告書の本文を組む側（#110）。⚠ **数える側（`RehearsalReport`）とは分ける。**
  #
  # 🔴 **分けたのは、数える側が `Metrics/ClassLength` の上限ぴったりだったから**
  # （2026-09-19・**200/200**）。⚠⚠ **`red?` に 1 行足すだけの修正（#362 / #368）が
  # 入らなくなっていた** — ⚠ **上限を上げて逃げると、次からは誰も分けない。**
  #
  # ⚠ **読むのは `RehearsalReport` の public な口だけ**（`@report.` で始まる）。
  # 🔴 **ivar を覗かない**ので、**数え方を変えても組み立て側は壊れない。**
  class RehearsalPresenter
    include Package

    # ⚠ 人が読む順。**投稿の経路を上から下へ追える並び。**
    # 🔴 **赤に関わる節は 1 か所に固まっていない**（`posts` / `notify` / `slow` / `http` /
    # `heartbeat`）— ⚠⚠ **2026-09-19 に `slow` と `heartbeat` が赤に入った**（#368 / #362）
    # ので、**「赤の判定に関わるものを上に置く」では並べられなくなった。**
    # ⚠ **赤の在り処は `RehearsalReport#red?` が正本**で、**この並びは読みやすさのため。**
    SECTIONS = [
      :header, :execs, :posts, :notify, :slow, :http, :heartbeat, :blind
    ].freeze

    def initialize(report)
      @report = report
    end

    def to_s
      return SECTIONS.filter_map {|section| send(:"format_#{section}")}.join("\n")
    end

    private

    def format_header
      unknown = RehearsalReport::UNKNOWN_REVISION
      versions = @report.versions.to_a.join(', ').presence || unknown
      revisions = @report.revisions.to_a.join(', ').presence || unknown
      out = ["ログ #{@report.lines} 行 / バージョン #{versions} / リビジョン #{revisions}"]
      # 🔴 **途中でデプロイが挟まった回は、結果を 1 つの版のものとして読めない**（#348 / #242）。
      # ⚠ **赤にはしない**（**リハーサルの終わり際に当てた回もここに出る**）が、⚠⚠ **見出しで言う。**
      out.push("⚠ 途中でリビジョンが変わった（#{@report.revisions.size} 種）") if @report.revisions.size > 1
      # ⚠⚠ **騙していたことを必ず出す。**⚠ **後から読む人が「本番のログ」と
      # 取り違えないため**（→ `TimeTravel` が毎ハートビートに `warn` を出すのと同じ理由）。
      out.push(format_travel) if @report.travel
      out.push('⚠ 日付を騙した痕跡が無い（実時間のログか、水準が warn を落としている）') unless @report.travel
      return out.join("\n")
    end

    def format_travel
      return "⚠ 日付を騙している: 出発 #{@report.travel[:start]} / scale #{@report.travel[:scale]}" \
        " / 投稿先 #{@report.travel[:mastodon]}"
    end

    def format_execs
      expected = RehearsalReport::EXPECTED_EXECS
      out = ['', "枠あたりの exec 回数（想定 #{expected} 回）"]
      @report.by_name.each do |name, row|
        mark = row[:range] == [expected, expected] ? '  ' : '🔴'
        out.push("#{mark} #{name}: #{row[:slots]} 枠 / exec #{row[:execs]} 回" \
          " / 枠あたり #{format_range(row[:range])}")
      end
      out.push('  （枠が 1 つも無い）') if @report.slots.empty?
      out.push("🔴 #{@report.anomalous_slots.size} 枠が想定と違う") if @report.anomalous_slots.any?
      return out.join("\n")
    end

    def format_range(range)
      return "#{range.first} 回" if range.first == range.last
      return "#{range.first}〜#{range.last} 回"
    end

    def format_posts
      out = ['', "投稿: 成功 #{@report.posted} 回（status #{@report.unique_posts} 件）" \
        " / 失敗 #{@report.failed} 回 / 沈黙 #{@report.silenced} 回"]
      # ⚠⚠ **赤にした理由を本文にも書く**（#127）。⚠ **終了コードだけが赤で、読んでも
      # どこが赤か分からない形にしない。**
      out.push("🔴 #{@report.failed} 回の投稿が落ちた") if @report.failed.positive?
      # 🔴 **500 が止まった世界で現れる壊れ方。**⚠ 回数の異常とは別に名指しする。
      @report.duplicated_slots.each do |(name, slot), row|
        out.push("🔴 #{name} #{slot} が #{row[:posts].uniq.size} 件の status を作った（重複投稿）")
      end
      return out.join("\n")
    end

    # ⚠ **履歴の通知**（#284）。🔴 **1 行も無いのが普通**（`@report.posted` を持つのは曲紹介だけ）
    # なので、**出ていないこと自体は異常ではない。**
    def format_notify
      return nil if @report.notifies.zero?
      out = ['', "履歴の通知: #{@report.notifies} 回 / 失敗 #{@report.notify_failures} 回"]
      # ⚠⚠ **赤にした理由を本文にも書く**（#127 と同じ）。
      out.push("🔴 #{@report.notify_failures} 回の通知が落ちた（投稿は出ているが履歴が伸びていない）") \
        if @report.notify_failures.positive?
      # 🔴 **落ちた回とは別に数える**（#348）。⚠⚠ **こちらは例外にならない** —
      # **`@report.posted` が `nil` を返しただけ**なので、**ログの上では成功した枠と同じ形に見える。**
      # ⚠ **赤にしないのは、履歴を切ってあれば毎枠出るから**（→ `count_notify`）。
      if @report.notify_misses.positive?
        out.push("⚠ #{@report.notify_misses} 回が履歴を伸ばさなかった（recorded:false）")
      end
      return out.join("\n")
    end

    # 🔴 **予算を超えて長くかかった枠**（#348 / #92）。⚠ **1 行も無いのが普通**なので、
    # **無ければ節そのものを出さない**（`format_notify` と同じ扱い）。
    def format_slow
      errors = @report.slow_errors
      return nil if @report.slows.empty? && errors.zero?
      out = ['', "予算を超えた枠: #{@report.slows.size} 回"]
      out += @report.slows.map do |row|
        "🔴 #{row[:post]} #{row[:slot]}: #{row[:seconds]} 秒（予算 #{row[:budget]} 秒）"
      end
      out.push("🔴 計測そのものが #{errors} 回落ちた（測れていない窓がある）") if errors.positive?
      # 🔴 **早送りを「割引」と読ませない**（Codex の P2・3 巡目）— ⚠⚠ **計測は monotonic なので
      # scale では伸びない。**⚠ **伸びるのは予定の側**（同じ所要が枠の scale 倍を食う → #90）
      # なので、**早送りの回はむしろ重く読む。**
      out.push('⚠ 計測は実時間（monotonic）。伸びるのは予定の側（scale 倍 → #90）') if scaled?
      return out.join("\n")
    end

    def format_http
      out = ['', 'HTTP']
      sorted = @report.http.sort_by {|(method, status), _| [method.to_s, status.to_i]}
      sorted.each do |(method, status), count|
        mark = status.to_i >= 400 ? '🔴' : '  '
        out.push("#{mark} #{method} #{status}: #{count} 回")
      end
      out.push('  （1 本も無い）') if @report.http.empty?
      out.push("⚠ 再送 #{@report.retries} 回") if @report.retries.positive?
      return out.join("\n")
    end

    def format_heartbeat
      out = ['', "ハートビート: #{@report.heartbeats} 回"]
      # 🔴 **痕跡が書けなかった回を名指しする**（#362）。⚠⚠ **`/healthz` はこの痕跡を読む**ので、
      # ⚠ **書けていない間は死活監視が古い値を見ている** — **赤にしてある**（→ `RehearsalReport#red?`）。
      if @report.heartbeat_errors.positive?
        out.push("🔴 痕跡の書き込みが #{@report.heartbeat_errors} 回落ちた（監視が古い値を見ていた）")
      end
      return out.join("\n")
    end

    # ⚠⚠ **読めていないものを毎回書く。**🔴 **「集計が緑だから大丈夫」と読ませない。**
    def format_blind
      out = ['', '⚠ この集計では読めないもの']
      out.push('- 沈黙した枠の exec 回数（本文が無いときの 1 行は `debug` → #114）') if @report.silenced.zero?
      out.push('- 実時間の経過に依存するもの（メモリ・接続の寿命・ログのローテート）')
      # 🔴 **数えているが赤にしないものを名指しする**（#348）。⚠⚠ **「集計が緑 ＝ 何も
      # 起きていない」と読ませない** — ⚠ **節には出ているので、見落とすのは終了コードだけを
      # 見たとき。**🔴 **`slow` は 2026-09-19 にここから外した**（**赤になったため** → #368）。
      out.push('- recorded:false は赤にしない（履歴を切った構成では毎枠出るため → #284）')
      out.push('- 外部が実時間で持つ制限（Mastodon のレート制限窓）')
      out.push('- 投稿が枠を跨ぐか（早送りでは見かけ上 scale 倍かかる → #90 / #92）') if scaled?
      return out.join("\n")
    end

    def scaled?
      return @report.travel.present? && @report.travel[:scale].to_i > 1
    end
  end
end
