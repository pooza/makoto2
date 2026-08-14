module Makoto
  # 用意した原稿を、枠の順に頭から消化する `PostingJob` の `source`。
  #
  # ⚠⚠ **`MessageSelector` は同じ段の中を乱択する。**1 日に 1 本しか出さない枠
  # （予告・開始告知）ならそれでよいが、⚠ **1 日に何本も出す枠では、同じ原稿が
  # 何度も出て、出ない原稿が残る。**前日増量（#13・11/3 に 8 本）がこれにあたる。
  #
  # ⚠ **順序は `Timetable#index_at`（枠の番号）から出す。**状態を持たないので
  # **落ちて戻ってきても位置がずれない**（→ docs/CLAUDE.md「進行位置は状態ではなく
  # 計算で出す」）。
  #
  # ⚠ **原稿が枠より少なければ頭に戻る。**無言の枠を作らない。
  class ScriptRotation
    include Package

    def initialize(selector:, timetable:)
      @selector = selector
      @timetable = timetable
    end

    # ⚠ 枠の外・原稿が無ければ nil（＝その枠は投稿しない）。
    def call(time = nil)
      time ||= Time.now
      index = @timetable.index_at(time)
      return nil unless index
      scripts = @selector.list(time)
      return nil if scripts.empty?
      return scripts[index % scripts.size][:body]
    end
  end
end
