module Makoto
  # ログの出口。⚠ **いまここに残っているのは「出す水準を設定から取る」だけ。**
  #
  # ## 🔴 文字コードの安全網とマスクは上流へ返した（#101 / 2026-08-24）
  #
  # ⚠⚠ **#79 / #82 / #97 でこのクラスに積んだ 3 つは、`ginseng-core` 1.19.0 が
  # すべて（しかもより厳密に）持っている。**⚠ **規約は「アプリ側リポジトリで
  # 回避策を持たない」**（→ docs/CLAUDE.md「`ginseng-*` との往復」）。
  #
  # | 積んでいたもの | 上流 | ⚠ 上流のほうが良い点 |
  # | --- | --- | --- |
  # | `scrub`（不正なバイト列） | `#518` | 🔴 **`force_encoding` ではなく `encode`** — ⚠⚠ **Shift_JIS が壊れない** |
  # | `warn` / `debug` / `fatal` を出口に通す | `#499` | ⚠ **ブロック形式を殺さない**（こちらは `ArgumentError` にしていた） |
  # | `drop_secrets`（上流が rescue で素の Hash を返す穴） | `#529` | 🔴 **fail closed** |
  # | — | `#493` | ⚠⚠ **URL のクエリの資格情報も落とす**（こちらに無かった） |
  #
  # ⚠ **fail closed ＝ マスクを通せなかったときは `_mask_error` とキー名だけを出し、
  # 中身を出さない**（こちらの `drop_secrets` は「上流が素の Hash を返す」ための保険だった）。
  #
  # 🔴 **出口の名前が変わった** — ⚠⚠ **`create_message` ではなく `create_entry`。**
  # ⚠ **`create_message` はマスク済みの Hash を返すだけで scrub はしない**
  # （不正なバイト列を落とすのは `create_entry` の側）。**テストもそちらを見る。**
  #
  # ⚠ **`error_message`（`Package`）は別物なので残る。**あちらは**例外を文字列に
  # 埋める**ためのもので、**ログを通らない**（`raise "...: #{error_message(e)}"`）。
  class Logger < Ginseng::Logger
    include Package

    # ⚠ 出す水準の既定。⚠⚠ **設定が読めないときはここへ倒す** — **黙る方向へは
    # 倒さない**（事故の大きいほうを避ける）。
    DEFAULT_LEVEL = 'info'.freeze

    def initialize(name = nil)
      super
      self.level = severity_level
    end

    private

    # 出す水準（#80 の黄 9）。
    #
    # ⚠⚠ **平常日に 171 行出ていた「本文が無い」を黙らせるために足した。**⚠ 枠は
    # 毎日空回りする設計なので、**それ自体は異常ではない**（→ `PostingJob`）。
    #
    # ⚠ **読めない値でも落ちない。**⚠⚠ **ログの出口が設定の不備で例外を上げると、
    # その例外を書く先も無い。**
    def severity_level
      name = (optional_config('/logger/level') || DEFAULT_LEVEL).to_s.upcase
      name = DEFAULT_LEVEL.upcase unless ::Logger::Severity.constants.include?(name.to_sym)
      return ::Logger::Severity.const_get(name)
    end
  end
end
