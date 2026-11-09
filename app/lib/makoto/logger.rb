module Makoto
  # ログの出口。⚠ **いまここに残っているものは無い**（`Package` を足すだけ）。
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
  #
  # ## 🔴 出す水準も上流へ返した（#605・ginseng-core 7.0.0）
  #
  # ⚠ **`/logger/level` は上流（`pooza/ginseng-core#755`）が読む。**書いていなければ debug（`Syslog::Logger` の
  # 既定）、読めない値は info に倒して warn を 1 行。⚠ makoto2 は `config/application.yaml` に `level: info` を
  # 書いており、綴りの誤りは schema の enum で `rake config:lint` が止める。
  class Logger < Ginseng::Logger
    include Package
  end
end
