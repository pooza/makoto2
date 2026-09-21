module Makoto
  # 本文の材料を UTF-8 へ寄せる口（#280）。
  #
  # ## 🔴 寄せないと、その枠が丸ごと消える
  #
  # ⚠ **`Sequel` / SQLite は非 ASCII を ASCII-8BIT で返しうる**（#124 / #79）。
  # ⚠⚠ **そういう文字列は、連結でも補間でも正規表現でも `Encoding::CompatibilityError`
  # を上げる** — 🔴 **受けるのは `PostingJob#create_text` の `rescue`** なので、
  # **`error` を 1 行残して、その枠は 1 文字も投稿されない。**
  #
  # ⚠ **#192 は `HashtagSource#join` だけを塞いだ**（**タグを足す都合で投稿そのものを
  # 失わない**）。⚠⚠ **同じ形は `0.5` で増えた「毎日出る枠」に素のまま残っていた** —
  # **朝挨拶（`MorningSource#call`）と曲紹介（`TrackPresenter`）**（#280）。
  #
  # ## ⚠⚠ 壊れるのは連結の行とは限らない
  #
  # 🔴 **曲紹介でいちばん先に落ちるのは、連結ではなく `TrackName` の正規表現**（実測）。
  # ⚠ **だから「連結の直前で寄せる」のでは足りない** — 🔴 **本文の材料が層へ入る
  # ところで寄せる**（`TrackPresenter` の各欄・`MorningSource` の原稿）。
  #
  # ## 🔴 判断は上流の実装に任せ、期待はこちらのテストで留める
  #
  # ⚠ **実体は `Ginseng::Fediverse::Text.to_utf8`**（`ginseng-fediverse#248` /
  # `#265` で決着し、`#277` で `TagContainer` から出た形・v3.1.0・#381）。
  # ⚠⚠ **こちらへ写さない** — **ラベルの貼り替えと `encode` の使い分けは、
  # 一度こちらで間違えて上流に直してもらった箇所**（→ docs/CLAUDE.md
  # 「`ginseng-*` との往復」・`HashtagSource#create_tags` の経緯）。
  #
  # | 来たもの | どうなる |
  # | --- | --- |
  # | ASCII-8BIT で中身が妥当な UTF-8 | 🔴 **ラベルだけ剥がす**（1 バイトも変えない） |
  # | Shift_JIS など名前のある符号化 | ⚠ **`encode` する**（中身を保つ） |
  # | 不正なバイト列 | ⚠⚠ **`Ginseng::ValidateError`** |
  #
  # 🔴 **`scrub` で黙って直さない。**⚠⚠ **化けた本文を投稿するくらいなら、その枠を
  # 落とすほうがよい** — ⚠ **`CompatibilityError` と違って、理由（元の符号化）が
  # `error` に残る。**
  #
  # 🔴 **`Text.relabel`（弾かない版）は使わない**（#381）。⚠⚠ **上流がそれを足したのは
  # 投稿の口のためで、こちらは「寄せられないものは落として `error` を残す」を
  # 明示の判断として持っている。**
  #
  # ## ⚠ 入口の名前を渡す（#381 ← `ginseng-fediverse#263`）
  #
  # 🔴 **呼び出し元は 4 つ**（`HashtagSource#join` / `MorningSource#call` /
  # `TrackPresenter` の前置きと各欄）。⚠⚠ **`PostingJob#create_text` の `rescue` が残す
  # `error` は、渡さないとどれで落ちたかを言わない** — **例外メッセージの末尾に
  # `(at <entry>)` が付く。**
  #
  # 🔴 **こちらが当てにしている振る舞いは `test/text.rb` に書いてある** —
  # ⚠ **上流が動いたら、黙ってずれるのではなくテストが赤くなる。**
  module Text
    # @param value [Object] 本文の材料。⚠ **`to_s` される**
    # @param entry [String, nil] ⚠ どの入口で寄せたか（弾かれたときのメッセージに付く）
    # @return [String] UTF-8 の文字列
    # @raise [Ginseng::ValidateError] 寄せられないとき
    def self.utf8(value, entry = nil)
      return Ginseng::Fediverse::Text.to_utf8(value, entry)
    end
  end
end
