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
  # ⚠ **段が変われば母集合も変わる**（季節の原稿がある月は季節の段が勝つ）。
  # **順送りは段の中だけ**で、⚠⚠ **段をまたいで連続することはある**が、
  # **その 2 本は別の原稿**（同じ原稿が続く形にはならない）。
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
      records = @selector.list(time || Time.now)
      return nil if records.empty?
      return records[index(time) % records.size]
    end

    private

    # ⚠ **日付の規則は `MessageSelector` が正本**（`/scheduler/timezone` で出す）。
    # ⚠⚠ **ここで `Date.today` を使わない** — **UTC のホストでは日付が 1 日ずれる。**
    def index(time)
      return @selector.date_of(time || Time.now).jd
    end

    def greeting_for(record)
      return nil if @greeting.blank?
      return nil unless @greeted_types.include?(record[:type].to_s)
      return @greeting
    end
  end
end
