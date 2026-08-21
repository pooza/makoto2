module Makoto
  class Config < Ginseng::Config
    include Package

    # 秘密情報を落とした設定のコピー。CLI の `makoto config` が使う。
    # 落とす対象は logger のマスク対象と同じキーで、両者がずれないよう
    # `/logger/mask_fields` を唯一の正本にしている。
    #
    # ⚠ fail-open な rescue の内側でこの設定値を読まないこと。読めなかった場合に
    # 「マスク対象が空 = 素通し」になる。読み出しはここで行い、失敗は例外のまま上げる。
    # 設定が JSON Schema を通らない箇所。⚠ **通れば空。**
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

    def secure_dump
      fields = self['/logger/mask_fields'].map(&:to_s)
      return each_with_object({}) do |(key, value), dest|
        dest[key] = fields.intersect?(key.split('/')) ? '(masked)' : value
      end
    end
  end
end
