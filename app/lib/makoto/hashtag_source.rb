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
      text = @source.call(time)
      return text if text.to_s.strip.empty?
      tags = create_tags(text)
      # ⚠⚠ **本文に既に入っていれば `TagContainer` が落とす。**⚠ **空になった
      # ときに改行だけ足さない**（タグの無い空行が最終行に残る）。
      return text if tags.empty?
      return [text.to_s.rstrip, tags].join("\n")
    end

    private

    def create_tags(text)
      container = Ginseng::Fediverse::TagContainer.new
      # ⚠ **本文は重複の判定にだけ使う**（投稿するのは元の文字列）。
      #
      # ⚠⚠ **`TagContainer#text=` は NFKC 正規化を通す**ので、⚠ **ASCII-8BIT の
      # 文字列を渡すと `Encoding::CompatibilityError` になる**（実測）。⚠⚠ **Sequel /
      # SQLite は非 ASCII を ASCII-8BIT で返しうる**（→ `Logger` / `Package#error_message`
      # が同じ穴を塞いでいる）。⚠ **そうなると `PostingJob` の rescue に飲まれて
      # その枠が落ちる** — **タグを足す都合で投稿そのものを失う**のは筋が違う。
      container.text = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      container.push(@hashtag)
      return container.to_s
    end
  end
end
