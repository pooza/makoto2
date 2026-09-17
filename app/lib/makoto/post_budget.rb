require 'uri'

module Makoto
  # 原稿 1 本に使える本文の長さ（#282）。
  #
  # 🔴 **原稿を書く側から 500 字の壁が見えなかった。**⚠⚠ **超えると投稿先が 422 を返し、
  # 再送なしの失敗としてその枠が消える**（`MastodonService::PERMANENT_STATUSES`）— ⚠ **気づくのは
  # 投稿の瞬間**で、**通年 366 本の朝挨拶を書き足していく箱**では、壁に当たるのは原稿が増えたとき。
  # 🔴 **だから取り込み（`ScriptImporter`）で弾く。**
  #
  # ## ⚠ 引くのは「前後に付く定型文」
  #
  # | type | 投稿の形 | 予約 |
  # | --- | --- | --- |
  # | **朝挨拶**（`/morning/type`） | 定型挨拶 ＋ 改行 ＋ 本文 | 挨拶の長さ ＋ 1 |
  # | **曲紹介の前置き** | 本文 ＋ 空行 ＋ 曲の行 | `TRACK_RESERVE` |
  # | **ライブの台本** | 本文 ＋ 改行 ＋ ハッシュタグ | タグの長さ ＋ 1 |
  # | それ以外 | 本文だけ | 0 |
  #
  # ⚠ **URL は投稿先と同じく 23 字と数える**（`holiday` は素の長さ 576 字だが実効 328 字）。
  class PostBudget
    include Package

    # 🔴 **Mastodon は URL の長さによらず 23 字と数える。**
    URL_LENGTH = 23

    # ⚠⚠ **曲の行（曲名・名義・アルバム名・URL）に取っておく長さ。**🔴 **実測の最大は 277 字**
    # （2026-09-08・`bgm`・名義 102 字 → #282）＋ 空行 2 字に余裕を持たせた。
    # ⚠ **曲は抽選なので、前置きの側でどの曲に付くかは決められない** ＝ 最悪に合わせる。
    TRACK_RESERVE = 300

    # 投稿先が数える長さ。
    def self.length(text)
      text = text.to_s
      urls = URI.extract(text, ['http', 'https'])
      return text.length - urls.sum(&:length) + (urls.size * URL_LENGTH)
    end

    def limit
      return config['/mastodon/max_length'].to_i
    end

    # その type の原稿が使える長さ。
    def budget(type)
      return limit - reserve(type.to_s)
    end

    # ⚠ **超えていれば `ValidateError`**（どれだけ超えたかを言う）。
    def validate(type, body, slug)
      length = self.class.length(body)
      allowed = budget(type)
      return if length <= allowed
      raise Ginseng::ValidateError,
        "#{slug}: 本文が長すぎます（#{length} 字 / この type は #{allowed} 字まで・URL は #{URL_LENGTH} 字と数える）"
    end

    private

    def reserve(type)
      return reserves.fetch(type, 0)
    end

    # ⚠ **type は設定から引く**（書き写さない）。⚠⚠ **同じ type が複数の形に出たら大きいほう。**
    def reserves
      unless @reserves
        @reserves = {}
        add_reserve(Song.new.prefix_types, TRACK_RESERVE)
        add_reserve(Live.new.types, config['/live/hashtag'].to_s.length + 1)
        add_reserve(Morning.new.type, greeting_reserve)
      end
      return @reserves
    end

    def add_reserve(types, value)
      Array(types).each {|type| @reserves[type.to_s] = [@reserves[type.to_s].to_i, value].max}
    end

    def greeting_reserve
      greeting = Morning.new.greeting
      return 0 if greeting.empty?
      return greeting.length + 1
    end
  end
end
