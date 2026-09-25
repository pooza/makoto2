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
      :header, :execs, :rejects, :posts, :notify, :slow, :http, :heartbeat, :unclassified, :blind
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
      # 🔴 **枠が 0 は赤**（#416）。⚠ **「何も落ちていない」ではなく「何も見ていない」。**
      out.push('🔴 枠が 1 つも無い（入力を間違えたか、常駐が起きていない）') if @report.slots.empty?
      out.push("🔴 #{@report.anomalous_slots.size} 枠が想定と違う") if @report.anomalous_slots.any?
      return out.join("\n")
    end

    # 🔴 **起動時の検査で登録を見送った投稿**（#416 / #350）。⚠ **1 行も無いのが普通**なので、
    # **無ければ節ごと出さない。**
    def format_rejects
      return nil if @report.rejects.empty?
      out = ['', "登録を見送った投稿: #{@report.rejects.size} 本"]
      out += @report.rejects.map {|row| "🔴 #{row[:post]}: #{row[:reason]}"}
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
      out.push(format_proxy_added) if @report.proxy_added || @report.proxy_skipped.positive?
      return out.join("\n")
    end

    # 🔴 **モロヘイヤが足した字数**（#351）。⚠ **`/mastodon/proxy_reserve` は実測から引いた値**
    # （→ `config/application.yaml`）だが、**辞書は稼働中のモロヘイヤ側で増えうる**ので、
    # **毎回この行で突き合わせる。**
    #
    # 🔴🔴 **超えても赤にしない。**⚠⚠ **予約を超えただけでは投稿は落ちない** — **落ちるのは
    # `本文 + 足された分 > /mastodon/max_length`（3000 字）のとき**で、⚠ **原稿の実効長は
    # 最長でも 328 字**なので、**予約を超えても上限まではまだ遠い。**🔴 **赤の在り処は
    # `RehearsalReport#red?` が正本**（→ このクラスの `SECTIONS` のコメント）なので、
    # ⚠ **ここで 🔴 を出して `red?` と食い違わせない。**
    def format_proxy_added
      row = @report.proxy_added
      skipped = @report.proxy_skipped
      return "⚠ モロヘイヤが足した字数: 1 本も測れていない（#{skipped} 本）" unless row
      # 🔴 **予約が 0 でも印を付ける**（Codex の P2）。⚠⚠ **`/mastodon/proxy_reserve` は
      # `optional_config` の既定 0**（`PostBudget`）なので、**設定が落ちた窓では予約ゼロ** —
      # ⚠ **足された分が 1 字でも上限を食う ＝ いちばん見たい状態。**
      reserve = optional_config('/mastodon/proxy_reserve', 0).to_i
      # ⚠ **印が無いときは 2 スペース**（🔴 **`format_execs` / `format_http` と同じ列**）。
      mark = row[:max] > reserve ? '⚠' : '  '
      out = ["#{mark} モロヘイヤが足した字数: #{row[:count]} 本 / min #{row[:min]}" \
        " / median #{row[:median]} / max #{row[:max]}（予約 #{reserve}）"]
      # 🔴 **一部だけ測れた回を「測れた」と読ませない**（Codex の P2）。
      out.push("⚠ #{skipped} 本は測れていない（この分布に最大が居るとは限らない）") if skipped.positive?
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
      return (out + format_durations).join("\n")
    end

    # 🔴 **1 本あたりの所要**（#201）。⚠⚠ **早送りの回の `seconds` は見かけ**なので、
    # ⚠ **単位を名乗ってから実時間を併記する**（→ `RehearsalReport#http_durations`）。
    #
    # 🔴 **2026-09-23 まで、docs も #201 も見かけを実時間と読み、そこへもう一度 scale を
    # 掛けていた** — ⚠⚠ **「中央値 6.772 秒 ＝ scale 10 で見かけ 67 秒」と書いていたが、
    # 6.772 秒がすでに見かけ**（**実時間 0.677 秒**）。🔴 **枠の間隔（見かけ 180 秒）に対して
    # 37% ではなく 3.7%。**⚠ **毎回この行が出れば、同じ取り違えは二度と起きない。**
    def format_durations
      unit = scaled? ? '（見かけ）' : ''
      return @report.http_durations.sort.flat_map do |method, row|
        lines = ["   #{method} の所要#{unit}: #{row[:count]} 本 / #{format_stats(row)}"]
        lines.push("   #{method} の所要（実時間）: #{format_stats(scale_down(row))}") if scaled?
        lines
      end
    end

    def format_stats(row)
      return "min #{row[:min]} / median #{row[:median]} / max #{row[:max]} 秒"
    end

    # 🔴 **見かけ ÷ scale ＝ 実時間。**⚠ **`scaled?` が真のときだけ呼ぶ**（`scale` は 2 以上）。
    def scale_down(row)
      scale = @report.travel[:scale].to_f
      return row.slice(:min, :median, :max).transform_values {|value| (value / scale).round(3)}
    end

    def format_heartbeat
      out = ['', "ハートビート: #{@report.heartbeats} 回"]
      # 🔴 **0 回は赤**（#416）。⚠ **常駐が起きていないか、別の unit を読んでいる。**
      out.push('🔴 ハートビートが 1 回も無い（常駐が起きていないか、別の unit を読んでいる）') \
        if @report.heartbeats.zero?
      # 🔴 **痕跡が書けなかった回を名指しする**（#362）。⚠⚠ **`/healthz` はこの痕跡を読む**ので、
      # ⚠ **書けていない間は死活監視が古い値を見ている** — **赤にしてある**（→ `RehearsalReport#red?`）。
      if @report.heartbeat_errors.positive?
        out.push("🔴 痕跡の書き込みが #{@report.heartbeat_errors} 回落ちた（監視が古い値を見ていた）")
      end
      return out.join("\n")
    end

    # 🔴 **どの受け皿にも入らなかった `error` 行**（#416）。⚠⚠ **名札は行の欄から作る**
    # （→ `RehearsalReport::LABEL_KEYS`）ので、**新しい形の行でも、どこで落ちたかが出る。**
    def format_unclassified
      return nil if @report.unclassified.empty?
      out = ['', "集計の受け皿に入らなかった error 行: #{@report.unclassified.values.sum} 行"]
      out += @report.unclassified.map {|label, count| "🔴 #{label}: #{count} 行"}
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
      # 🔴 **経由していない回は足された分を測れない**（#351）。⚠⚠ **迂回の回を「足されなかった」
      # と読ませない** — ⚠ **モロヘイヤが何もしていないだけ。**
      # 🔴 **1 本でも測れていなければ言う**（Codex の P2）— ⚠⚠ **部分的な取りこぼしを
      # 「測れた」と読ませない**（**分布に最大が居るとは限らない**）。
      out.push('- モロヘイヤが足した字数（迂回・content 無し・復元できない形は測れない → #351）') \
        if @report.proxy_added.nil? || @report.proxy_skipped.positive?
      # 🔴 **所要に再送ぶんが入っていないことを言う**（#201）。⚠⚠ **落ちた試行の行は
      # `seconds` を持たない**ので、⚠ **再送が多い回ほど「1 本の所要」は実態より軽く出る。**
      out.push('- 再送で食った時間（落ちた試行の行は seconds を持たない → #201）') \
        if @report.retries.positive?
      out.push('- 投稿が枠を跨ぐか（早送りでは見かけ上 scale 倍かかる → #90 / #92）') if scaled?
      return out.join("\n")
    end

    def scaled?
      return @report.travel.present? && @report.travel[:scale].to_i > 1
    end
  end
end
