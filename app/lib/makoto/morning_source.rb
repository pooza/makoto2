module Makoto
  # 朝挨拶の本文（#17）。**定型挨拶 ＋ その日の原稿 1 本**を組む。
  #
  # ```
  # おはよう！みんな、元気してるかな？剣崎真琴です。   ← 定型挨拶（ここが付ける）
  # 昨日は、前髪を切りに行きました！さっぱり。          ← morning から 1 本
  # ```
  #
  # ⚠⚠ **`morning` 237 件に「おはよう」は 1 件も無い**（実測 0 件・→
  # [makoto-legacy.md](../../../docs/makoto-legacy.md)「朝挨拶原稿の仕様」）。
  # 🔴 **欠落ではなく、定型文だから原稿に入れていない** — ⚠ **これを知らずに原稿を
  # そのまま流すと、挨拶なしの投稿になる。**
  #
  # ⚠ **日付が特定された原稿（`holiday`）には付けない。**⚠⚠ **そちらは挨拶を原稿が
  # 自分で持つ**（4/1 の「神☆アイドル、剣崎☆真琴です☆」のようなおふざけは、定型挨拶
  # ごと差し替わる形 → #12 / #50）。
  #
  # ## 🔴 引くのは乱択ではなく日付の順送り
  #
  # ⚠⚠ **#17 の完了条件は「連日で同じ挨拶が続かない」。**⚠ **`MessageSelector` は
  # 同じ段の中を乱択する**ので、**1 日 1 本の枠では連日で同じ原稿を引きうる**
  # （155 件でも 1 年に 2 回程度は起きる）。
  #
  # 🔴 **日数（ユリウス通日）で順に送る。**⚠ **状態を持たない**ので、落ちて戻って
  # きても・別の箱で下見しても同じ日には同じ原稿が出る（→
  # [CLAUDE.md](../../../docs/CLAUDE.md)「進行位置は状態ではなく計算で出す」）。
  # ⚠⚠ **`ScriptRotation` の「枠の番号で送る」は使えない** — **1 日 1 枠なので
  # 番号が毎日 0 になる。**
  #
  # ## 🔴 季節の原稿は月の中に散らす。順送りの母集合は動かさない
  #
  # ⚠⚠ **母集合が日ごとに入れ替わると、順送りだけでは連日で同じ原稿になりうる**
  # （Codex の P1 / P2）。⚠ **大きさの違う配列を独立に割るので、月替わりで同じ位置に
  # 落ちる。**🔴 **実データの 5 月は季節の原稿が 1 件しかない**ので、**段 4 が毎日
  # 勝つ形だと 31 日とも同じ挨拶**にもなる。
  #
  # 🔴 **そこで、通年の原稿（段 5）を「動かない母集合」として毎日順に送り、季節の原稿
  # （段 4）はその月の中へ等間隔で差し込む。**
  #
  # | | |
  # | --- | --- |
  # | **季節の日** | ⚠ **月の日数 ÷ 季節の原稿の件数**で散らした日。**5 月なら 1 日だけ** |
  # | **それ以外の日** | 🔴 **通年の原稿を順送り**（母集合は 1 年を通して動かない） |
  #
  # - ⚠ **連日で同じにならない** — **季節どうしは別の原稿**（番号が 1 つ進む）、
  #   **季節と通年は別の原稿**（母集合が交わらない）、**通年どうしは位置が 1 つ進む**
  # - ⚠⚠ **段の順そのものは変えていない**（#12 の「具体的なものが勝つ」）。
  #   **日付が特定された原稿（段 1 / 2）と記念日（段 3）が勝つ日は、そのまま出す**
  # - ⚠ **季節の原稿の割合は「その月に何件あるか」で決まる。**実データは 82 / 237 で、
  #   **12 月は 25 件（31 日中 25 日）・5 月は 1 件**（→ makoto-legacy.md）
  class MorningSource
    include Package

    # @param selector [MessageSelector] 原稿を引く口
    # @param greeting [String] 定型挨拶。⚠ 空なら付けない
    # @param greeted_types [Array<String>] 定型挨拶を付ける type（＝日替わりの type）
    def initialize(selector:, greeting: nil, greeted_types: nil)
      @selector = selector
      @greeting = greeting.to_s
      @greeted_types = Array(greeted_types).map(&:to_s)
    end

    # ⚠ **原稿が 1 件も無ければ nil**（＝その日は投稿しない）。
    def call(time = nil)
      time ||= Time.now
      record = find(time)
      # ⚠ **`list` は `MessageSelector#call` を通らない**ので、⚠⚠ **予約された日に
      # 引けなかったときの警告はここから呼ぶ**（→ `ScriptRotation` と同じ・#114）。
      return @selector.report_silence(time) unless record
      return [greeting_for(record), record[:body]].compact.join("\n")
    end

    # その日の原稿。⚠ **`Date` をそのまま渡せる**（下見が時刻を作るとホストの TZ で
    # 1 日ずれる → `MessageSelector#find`）。
    def find(time = nil)
      # ⚠ **日付の規則は `MessageSelector` が正本**（`/scheduler/timezone` で出す）。
      # ⚠⚠ **ここで `Date.today` を使わない** — **UTC のホストでは日付が 1 日ずれる。**
      date = @selector.date_of(time || Time.now)
      records = @selector.list(date)
      return nil if records.empty?
      # ⚠ **日付が特定された原稿・記念日が勝った日は、その段の中で順に送る。**
      return rotate(records, date) unless rotating?(records, date)
      return seasonal(date) || rotate(@selector.undated_list(date), date)
    end

    private

    # その日が「季節の原稿の日」なら、その原稿。⚠ **違えば nil。**
    #
    # ⚠⚠ **月の中に等間隔で置く。**⚠ **件数が日数より多ければ毎日**（12 月は 25 件）、
    # **1 件なら月に 1 日だけ**（5 月）。
    def seasonal(date)
      records = @selector.season_list(date)
      return nil if records.empty?
      index = slot_of(date, records.size)
      return nil unless index
      return records[index]
    end

    # その日が何番目の季節の原稿の日か。⚠ **番号が変わる日だけがその原稿の日。**
    def slot_of(date, size)
      days = Date.new(date.year, date.month, -1).day
      index = ((date.day - 1) * size) / days
      return nil if date.day > 1 && (((date.day - 2) * size) / days) == index
      return index
    end

    # ⚠ **通年で回す段が勝った日か**（＝ 季節・無指定）。🔴 **type ではなく実体で見る**
    # （記念日の type は通年の母集合に入らない → `MessageSelector#rotating_types`）。
    def rotating?(records, date)
      ids = (@selector.season_list(date) + @selector.undated_list(date)).map {|record| record[:id]}
      return ids.include?(records.first[:id])
    end

    def rotate(records, date)
      return nil if records.empty?
      return records[date.jd % records.size]
    end

    def greeting_for(record)
      return nil if @greeting.blank?
      return nil unless @greeted_types.include?(record[:type].to_s)
      return @greeting
    end
  end
end
