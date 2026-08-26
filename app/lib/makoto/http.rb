module Makoto
  # HTTP の口。⚠ **いまここに残っているのは `Package` の差し替えだけ。**
  #
  # 🔴 **`Makoto::Package` を include するために存在する** — ⚠⚠ **`Ginseng::HTTP` は
  # `logger_class` / `config_class` / `environment_class` を `Package` 経由で引く**ので、
  # **素の `Ginseng::HTTP` を使うと gem 側の Environment（＝ gem のルート）を見る。**
  #
  # ## 🔴 タイムアウトの回避策は上流へ返した（#137 / 2026-08-24）
  #
  # ⚠⚠ **`/http/timeout/seconds` が `get` / `post` に効かず、実効が Net::HTTP 既定の
  # 60 秒だった**（#90 / #80 の黄 2）ので、⚠ **5 メソッドを上書きして `timeout:` を
  # 足していた。**✅ **`ginseng-core` 1.19.0（上流 `#514`）が `options[:timeout] ||=
  # timeout` を渡すようになった**ので、**上書きは不要になった。**
  #
  # ⚠ **呼ぶ側が明示した値を上書きしない**という約束もそのまま（`upload` は元から
  # 自分で渡している）。⚠⚠ **インスタンス単位で変えたいときは `http.timeout = 10`。**
  #
  # ## ⚠⚠ これは wall-clock の上限ではない（#92）
  #
  # ⚠ **HTTParty の `timeout` は Net::HTTP の 1 回の socket 操作ごとに効く。**
  # ⚠⚠ **チャンクをこの秒数より短い間隔で送り続ける相手は、いつまでも掴んでいられる。**
  # **「1 本の投稿が必ず枠の中で終わる」とまでは言えない**（→ **#92**・`0.6`）。
  #
  # ⚠ **それでも設定が効いている価値はある** — **黙って止まっている相手**（応答が
  # 1 バイトも来ない）が実際にありうる形で、⚠⚠ **既定の 60 秒では再送と合わせて
  # 枠を跨いでいた。**
  class HTTP < Ginseng::HTTP
    include Package
  end
end
