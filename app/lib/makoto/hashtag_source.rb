module Makoto
  # 本文の最終行にハッシュタグを足す `PostingJob` の `source`（#64）。
  #
  # ⚠⚠ **最終行をハッシュタグだけの行にする**（→ docs/CLAUDE.md「リハーサルを見て
  # 決めた微調整」）。本文の末尾に続けて書かない。
  #
  # ⚠⚠ **これは Mastodon の仕様に由来する**（2026-08-19 訂正）。⚠ **かつてここに
  # 「モロヘイヤがその形を処理するため」と書いていたのは誤り**（#80 の緑 11 で
  # 一度直したときも、否定しただけで正しい根拠を書けていなかった）。
  #
  # ⚠⚠ **タグの直前の空行はここで足さない。**⚠ **モロヘイヤが勝手に入れる**ので、
  # ここで入れると二重になる。⚠ **投稿はモロヘイヤ経由**（#124 → `MastodonService`）。
  #
  # ⚠⚠ **MAKOTO が自分で付けるタグはここの 1 つだけ**（2026-08-19 決定）。
  # ⚠ **`#precure_fun` 等はモロヘイヤに任せる** — **旧アカウントの朝挨拶に 10 年
  # 付いていたのもモロヘイヤのタグ付け**であって、MAKOTO は出していなかった。
  #
  # ⚠ **原稿の側に書き足さない。**告知や MC は原稿なので YAML に書けば入るが、
  # **曲の投稿は原稿ではない**（`TrackPresenter` が組む）。⚠ 原稿側に手で書くと
  # **曲だけタグが付かないか、原稿の書き忘れが出る**ので、ライブの枠すべてを
  # ここで包む。
  #
  # ⚠⚠ **本文が無いときはタグも出さない。**`source` が nil を返すのは「その枠は
  # 投稿しない」という合図（原稿が無い日・ライブ当日でない日）。⚠ ここでタグを
  # 足すと**タグだけの投稿が毎日出る。**
  # ⚠ **タグの組み立ては上流の `Ginseng::Fediverse::TagContainer` に任せる**
  # （2026-08-19）。⚠⚠ **本文に既に同じタグがあれば足さない**のが本体で、
  # **`#` の付け忘れと語中の空白（`SONGBIRD PARTY` → `#SONGBIRD_PARTY`）も吸収する。**
  # ⚠ **ここは「どの枠に付けるか」だけを持ち、タグの書式は持たない。**
  class HashtagSource
    include Package

    # @param source [#call] 包む `source`
    # @param hashtag [String, nil] 足すハッシュタグ。⚠ **空なら何もしない**
    def initialize(source:, hashtag: nil)
      @source = source
      @hashtag = hashtag.to_s
    end

    def call(time = nil)
      return tag(@source.call(time))
    end

    # 本文にタグを足す。
    #
    # ⚠ **`call` から切り出してある**のは、🔴 **下見が「投稿される本文」を自分で
    # 組み立て直さないため**（#159）。⚠⚠ **下見は既に組んだ並びから本文を作るので、
    # `call` の「時刻から引き直す」経路は通れない** — **通すと並びを 2 回組むことに
    # なり、下見が防ごうとしている食い違いを下見自身が作る**（Codex の指摘・PR #160）。
    def tag(text)
      return text if blank?(text)
      tags = create_tags(text)
      # ⚠⚠ **本文に既に入っていれば `TagContainer` が落とす。**⚠ **空になった
      # ときに改行だけ足さない**（タグの無い空行が最終行に残る）。
      return text if tags.empty?
      return [text.to_s.rstrip, tags].join("\n")
    end

    private

    # ⚠ **本文は重複の判定にだけ使う**（投稿するのは元の文字列）。
    #
    # ## 🔴 変換は上流へ返した（#171 / 2026-08-24）
    #
    # ⚠⚠ **`force_encoding(UTF_8).scrub` を掛けていた**（`TagContainer#text=` が
    # NFKC を通すので、ASCII-8BIT を素で渡すと `Encoding::CompatibilityError`）。
    # ⚠ **`Sequel` / SQLite は非 ASCII を ASCII-8BIT で返しうる。**
    #
    # 🔴 **あれは上流（`ginseng-fediverse#248`）が「採らない」と決めた形そのものだった**
    # — ⚠⚠ **`force_encoding` はラベルを貼り替えるだけ**なので、**Shift_JIS の本文は
    # 中身が壊れたまま UTF-8 を名乗り、`scrub` がそれを `?` に置き換える。**
    # ⚠ **化けた文字列で重複を判定していた**（＝ **既に本文にあるタグを取りこぼす**）。
    #
    # ✅ **1.8.30 の `TagContainer.to_utf8` が入口で `encode` する**ので、⚠ **ASCII-8BIT
    # も Shift_JIS も中身を保ったまま通る。**⚠⚠ **不正なバイト列だけが `ValidateError`。**
    #
    # 🔴 **タグを足す都合で投稿そのものを失わない**（元の判断はそのまま）ので、
    # ⚠ **`ValidateError` は握ってタグ無しで返す。**⚠⚠ **黙らせない** —
    # **本文が壊れていることに気付ける唯一の場所。**
    def create_tags(text)
      container = Ginseng::Fediverse::TagContainer.new
      container.text = utf8(text)
      container.push(@hashtag)
      return container.to_s
    rescue Ginseng::ValidateError => e
      logger.warn(hashtag: 'skipped', error: e)
      return ''
    end

    # ⚠ **本文が空か。**🔴 **不正なバイト列でも落ちないこと。**
    #
    # ⚠⚠ **`String#strip` は不正なバイト列で `Encoding::CompatibilityError` を上げる**
    # ので、**ここで素の `strip` を呼ぶと `PostingJob` の rescue に飲まれて枠が落ちる**
    # — ⚠ **タグを足す都合で投稿そのものを失う**という、`create_tags` の rescue が
    # 避けているのと同じ形が、**その手前に残っていた**（#171 で見つけた）。
    #
    # ⚠ **落ちたときは「空ではない」に倒す** — **本文はあるので、投稿はする。**
    def blank?(text)
      return text.to_s.strip.empty?
    rescue ArgumentError, EncodingError
      return false
    end

    # ⚠ **ASCII-8BIT のラベルだけを剥がす**（⚠⚠ **中身が妥当な UTF-8 のときだけ**）。
    #
    # 🔴 **暫定** — **上流の `TagContainer.to_utf8` は ASCII-8BIT を `encode` に掛ける**
    # ので、⚠⚠ **中身が妥当な UTF-8 でも `UndefinedConversionError` → `ValidateError`
    # になる**（実測・`pooza/ginseng-fediverse#265`）。⚠ **`Sequel` / SQLite が非 ASCII を
    # ASCII-8BIT で返す形がまさにこれ**（#124 / #79）で、**当たるとタグが黙って消える。**
    #
    # ⚠⚠ **これは #248 が「採らない」と決めた `force_encoding` とは違う** —
    # **妥当な UTF-8 であることを確かめてからラベルを直すだけ**で、🔴 **中身は 1 バイトも
    # 変えないし、`scrub` もしない。**⚠ **上流が直ったら消す。**
    def utf8(text)
      text = text.to_s
      return text unless text.encoding == Encoding::BINARY
      relabeled = text.dup.force_encoding(Encoding::UTF_8)
      return relabeled.valid_encoding? ? relabeled : text
    end
  end
end
