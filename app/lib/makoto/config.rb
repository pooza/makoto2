module Makoto
  class Config < Ginseng::Config
    include Package

    # 秘密情報を落とした設定のコピー。CLI の `makoto config` が使う。
    # 落とす対象は logger のマスク対象と同じキーで、両者がずれないよう
    # `/logger/mask_fields` を唯一の正本にしている。
    #
    # ⚠ fail-open な rescue の内側でこの設定値を読まないこと。読めなかった場合に
    # 「マスク対象が空 = 素通し」になる。読み出しはここで行い、失敗は例外のまま上げる。
    def secure_dump
      fields = self['/logger/mask_fields'].map(&:to_s)
      return each_with_object({}) do |(key, value), dest|
        dest[key] = fields.intersect?(key.split('/')) ? '(masked)' : value
      end
    end
  end
end
