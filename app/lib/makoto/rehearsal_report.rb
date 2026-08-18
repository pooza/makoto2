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
  # ## ⚠⚠ 数えられないもの
  #
  # 🔴 **沈黙した枠の exec 回数は数えられない。**⚠ **本文が無いときの 1 行は
  # `debug`** で、⚠⚠ **既定の水準（`info`）では出ない**（→ #114）。**#114 が入るまで、
  # 「出るべき日に出なかった枠」はこの集計にも現れない。**
  class RehearsalReport
    include Package

    # 枠あたりの想定 exec 回数。⚠ **これ以外は赤にする。**
    EXPECTED_EXECS = 1

    # ⚠ 人が読む順。**赤の判定に関わるものを上に置く。**
    SECTIONS = [
      :header, :execs, :posts, :http, :heartbeat, :blind
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
      lines.each {|line| consume(parse(line))}
    end

    attr_reader :slots, :http, :retries, :heartbeats, :versions, :travel, :lines

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
    def red?
      return anomalous_slots.any? || duplicated_slots.any? || http_errors.positive?
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
      return count_slot(entry) if entry[:post] && entry[:slot]
      return count_http(entry) if entry[:method] && entry[:url]
      return count_heartbeat(entry) if entry[:scheduler] == 'heartbeat'
      return @travel = entry[:time_travel] if entry[:time_travel]
      return nil
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

    # ⚠ **応答が返った行と、落ちた試行の行を分ける。**⚠⚠ **後者は `count` を持ち、
    # 再送の回数そのもの**なので、`status` ごとの内訳には混ぜない。
    def count_http(entry)
      return @retries += 1 if entry[:count]
      key = [entry[:method], entry[:status]]
      @http[key] = @http.fetch(key, 0) + 1
      return @http[key]
    end

    def count_heartbeat(entry)
      @heartbeats += 1
      @versions.add(entry[:version].to_s) if entry[:version]
      return @heartbeats
    end

    def format_header
      out = ["ログ #{@lines} 行 / バージョン #{@versions.to_a.join(', ').presence || '(不明)'}"]
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
      # 🔴 **500 が止まった世界で現れる壊れ方。**⚠ 回数の異常とは別に名指しする。
      duplicated_slots.each do |(name, slot), row|
        out.push("🔴 #{name} #{slot} が #{row[:posts].uniq.size} 件の status を作った（重複投稿）")
      end
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
      out.push('- 外部が実時間で持つ制限（Mastodon のレート制限窓）')
      out.push('- 投稿が枠を跨ぐか（早送りでは見かけ上 scale 倍かかる → #90 / #92）') if scaled?
      return out.join("\n")
    end

    def scaled?
      return @travel.present? && @travel[:scale].to_i > 1
    end
  end
end
