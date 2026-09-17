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
  # 🔴 **モロヘイヤを経由するときは、さらに `/mastodon/proxy_reserve` を全部の type から引く**
  # （転送時にタグの行を足すため）。
  #
  # ⚠ **URL は投稿先と同じく 23 字と数える**（`holiday` は素の長さ 576 字だが実効 328 字）。
  class PostBudget
    include Package

    # 🔴 **Mastodon は URL の長さによらず 23 字と数える。**
    URL_LENGTH = 23

    # ⚠ **`URI.extract` と同じ規則**（`http` / `https`）。
    URL_PATTERN = URI::RFC2396_PARSER.make_regexp(['http', 'https'])

    # ⚠⚠ **曲の行（曲名・名義・アルバム名・URL）に取っておく長さ。**🔴 **実測の最大は 277 字**
    # （2026-09-08・`bgm`・名義 102 字 → #282）＋ 空行 2 字に余裕を持たせた。
    # ⚠ **曲は抽選なので、前置きの側でどの曲に付くかは決められない** ＝ 最悪に合わせる。
    TRACK_RESERVE = 300

    # 投稿先が数える長さ。
    #
    # ⚠⚠ **書記素クラスタで数える**（Codex の P2）。🔴 **Mastodon は URL を置き換えたあと、見た目の
    # 1 文字（結合文字・ZWJ の絵文字）を 1 字と数える** — ⚠ **`String#length` はコードポイント
    # なので、家族の絵文字 1 つが数字ぶん長く出て、上限の近くで通る原稿を弾いてしまう。**
    #
    # ⚠⚠ **URL は 1 回の走査で置き換える**（Codex の P2）。🔴 **1 本ずつ `gsub` すると、前方一致
    # する URL（`/a` と `/a/b`）で短いほうが長いほうの中まで置き換え、長く数えてしまう。**
    def self.length(text)
      return text.to_s.gsub(URL_PATTERN) {'x' * URL_LENGTH}.grapheme_clusters.size
    end

    def limit
      return config['/mastodon/max_length'].to_i
    end

    # その type の原稿が使える長さ。
    #
    # ⚠⚠ **日付つきの朝挨拶には定型挨拶が付かない**（Codex の P2 → `MorningSource#greeting_for`
    # — **挨拶は原稿が自分で持つ**）。🔴 **type だけで挨拶の分を引くと、日付つきの原稿を 25 字
    # ぶん不当に弾く。**
    def budget(type, dated: false)
      return limit - proxy_reserve - reserve(type.to_s, dated: dated)
    end

    # 🔴 **モロヘイヤが転送時に足すタグのぶん**（Codex の P2）。⚠⚠ **経由しないなら 0。**
    def proxy_reserve
      return 0 unless config['/mastodon/mulukhiya']
      return optional_config('/mastodon/proxy_reserve', 0).to_i
    end

    # ⚠ **超えていれば `ValidateError`**（どれだけ超えたかを言う）。
    def validate(type, body, slug, dated: false)
      length = self.class.length(body)
      allowed = budget(type, dated: dated)
      return if length <= allowed
      raise Ginseng::ValidateError,
        "#{slug}: 本文が長すぎます（#{length} 字 / この type は #{allowed} 字まで・URL は #{URL_LENGTH} 字と数える）"
    end

    private

    def reserve(type, dated: false)
      value = reserves.fetch(type, 0)
      value = [value - greeting_reserve, 0].max if dated && type == Morning.new.type
      return value
    end

    # ⚠ **type は設定から引く**（書き写さない）。⚠⚠ **同じ type が複数の形に出たら大きいほう。**
    def reserves
      unless @reserves
        @reserves = {}
        add_reserve(Song.new.prefix_types, TRACK_RESERVE)
        add_reserve(Live.new.types, tag_reserve)
        add_reserve(Morning.new.type, greeting_reserve)
      end
      return @reserves
    end

    def add_reserve(types, value)
      Array(types).each {|type| @reserves[type.to_s] = [@reserves[type.to_s].to_i, value].max}
    end

    # ⚠⚠ **ハッシュタグは任意の設定**（`Live#hashtag` は `optional_config`）— 🔴 **素の `config[]`
    # で読むと、タグを外した設定ですべての取り込み（朝挨拶も）が落ちる**（Codex の P2）。
    #
    # ⚠⚠ **正規化した形で数える**（Codex の P2）。🔴 **`#` を書かない設定も `HashtagSource` は
    # 受け、`TagContainer` が `#` を足す**ので、素の設定値では 1 字短く出る。
    def tag_reserve
      hashtag = Live.new.hashtag
      return 0 if hashtag.empty?
      container = Ginseng::Fediverse::TagContainer.new
      container.push(hashtag)
      tags = container.to_s
      return 0 if tags.empty?
      return tags.grapheme_clusters.size + 1
    end

    def greeting_reserve
      greeting = Morning.new.greeting
      return 0 if greeting.empty?
      return greeting.grapheme_clusters.size + 1
    end
  end
end
