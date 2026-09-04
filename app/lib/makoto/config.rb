module Makoto
  class Config < Ginseng::Config
    include Package

    # 設定が JSON Schema を通らない箇所。⚠ **通れば空。**
    #
    # ⚠ fail-open な rescue の内側でこの結果を読まないこと。読めなかった場合に
    # 「異常なし」と読める。読み出しはここで行い、失敗は例外のまま上げる。
    #
    # ⚠⚠ **`errors` は呼ぶたびに schema 全体を回す**ので、60 秒間隔の監視から素で
    # 呼ぶと、⚠ **そのぶん CPU を使い続ける**（`Health` はリクエストごとに作られる
    # → `MonitorApp`）。**1 回だけ検証して覚える**（#99）。
    #
    # ⚠ **設定を書き換えたら `reload` で捨てる。**
    def validation_errors
      @validation_errors ||= errors.map {|message| message.to_s.sub(/ in schema .*\z/, '')}
      return @validation_errors
    end

    def reload
      @validation_errors = nil
      return super
    end

    # 秘密情報を落とした設定のコピー。CLI の `makoto config` が使う。
    #
    # 🔴 **落とす対象の正本は上流の合成**（`Ginseng::Masking#mask_fields` ＝
    # **gem の既定 ＋ `/logger/mask_fields`**）。⚠⚠ **設定ファイル単独ではない**
    # — 上流 `ginseng-core#586` で、設定は既定を**置き換える**のではなく
    # **合成する**ものになった。⚠ **ここが `/logger/mask_fields` だけを見ていた
    # あいだ、ログは 13 件落とすのに `makoto config` は 7 件しか落とさなかった**
    # （#216。`apikey` / `client_secret` / `refresh_token` が抜けていた）。
    #
    # 🔴 **`mask` ではなく `mask_fields` を呼ぶ。**⚠⚠ **`mask` は当たったキーを
    # 落とす**ので、**「伏せたことを見せる」この出力には使えない** — 設定を点検する
    # 人に**キーが在ること自体は見せる**のがこの口の役目で、消すと点検にならない
    # （そのために上流が `mask_fields` を公開した → `ginseng-core#624` / v1.23.5）。
    #
    # ⚠ **戻り値は凍っている**（上流がメモ化した現物を返す）。**書き換えないこと。**
    #
    # ⚠⚠ **設定が読めなくても空にはならない** — 上流は既定 9 件へ倒す
    # （`masking_list` の `rescue ConfigError`）。⚠ **そのとき落ちるのは `code`
    # だけ**（上流が意図して既定から外しており、こちらの列挙が唯一の根拠 →
    # #213）。🔴 **ログ側と同じ倒れ方なので、ここで別に読み直さない**（読み直すと
    # マスク対象の列が 2 か所に分かれ、また必ずズレる）。
    #
    # ⚠ **大文字小文字で判定を変えない。**上流の `mask_field?` は
    # `key.to_s.downcase` で見る（`Authorization` は HTTP ヘッダの綴りそのもの）。
    # ⚠⚠ **ここだけ完全一致にすると、ログでは伏せるのに CLI では平文**になる。
    def secure_dump
      fields = logger.mask_fields
      return each_with_object({}) do |(key, value), dest|
        dest[key] = fields.intersect?(key.split('/').map(&:downcase)) ? '(masked)' : value
      end
    end
  end
end
