module Makoto
  # 曲 1 本ぶんの投稿本文。ライブ（#13）が使い、日常の曲紹介（#16）も同じ形を使う。
  #
  # ⚠⚠ **画像を添付しない。URL を貼って SNS 側のプレビューカードに任せる**
  # （→ docs/CLAUDE.md「画像添付は実装しない」）。⚠ **これは SNS 側の機能なので、
  # 出力先を抽象化しても失われない。**
  #
  # ⚠ **モロヘイヤ経由だと `ItunesImageHandler` が画像も付けて二重になりうる。**
  # #16 で実機確認して、必要ならモロヘイヤ側で切る。
  #
  # ## ⚠⚠ ライブの都合はライブが渡す
  #
  # 🔴 **ここは「どちらでも使える形」を持ち、どちらにするかは呼ぶ側が決める**
  # （`cover_prefix` と同じ）。⚠ **ライブと日常で判断が違う**ため:
  #
  # | | ライブ（#13） | 日常の曲紹介（#16） |
  # | --- | --- | --- |
  # | 括弧書き（#119） | ⚠ **落とす**（供給元の但し書きは読む側の役に立たない） | 落とさない |
  # | 自分名義（#121） | 🔴 **出さない**（歌っているのが自分であることが自明） | 出す |
  # | ⚠ 感嘆符・疑問符（#120） | **揃える** | ⚠⚠ **揃える**（こちらは共通） |
  # | ⚠ アルバム名 | 出さない（**曲だけを並べる 8 時間**） | 🔴 **劇伴では出す**（#16・下記） |
  #
  # ## 🔴 劇伴はアルバム／シリーズを主役にする（#16）
  #
  # ⚠⚠ **`bgm` の名義は作曲家**（`林ゆうき` / `高梨康治`）で、**どのシリーズの曲かは
  # 名義からは分からない。**⚠ **曲名にも色気が無い**（`星を追われし者`）ので、
  # 🔴 **文脈を持っているのはアルバム名だけ**（`スター☆トゥインクルプリキュア
  # オリジナル・サウンドトラック2`）。
  #
  # ⚠ **`instrumental` も同じ**（劇伴盤に入っている歌のインスト）。⚠⚠ **`karaoke` /
  # `tv_size` は名義が歌手そのもの**なので、**アルバム名は文脈を足さない。**
  #
  # 🔴 **どの `kind` で出すかはここが決めない**（`cover_prefix` と同じ）— **呼ぶ側が
  # 設定から渡す**（`/song/collection_kinds`）。
  class TrackPresenter
    # @param track [Hash] `track` テーブルの 1 行
    # @param prefix [String, nil] 曲名の前に置く一言（カバーの断りなど）
    # @param plain_name [Boolean] ⚠ 曲名から括弧書きを落とすか（#119）
    # @param artist [Boolean] ⚠ 名義を出すか（#121）
    # @param collection [Boolean] ⚠ アルバム名を出すか（#16）
    def initialize(track, prefix: nil, plain_name: false, artist: true, collection: false)
      @track = track
      # 🔴 **本文の材料は入口で UTF-8 へ寄せる**（#280 → `Text`）。
      @prefix = Text.utf8(prefix)
      @plain_name = plain_name
      @artist = artist
      @collection = collection
    end

    # 表示する曲名。⚠ **感嘆符・疑問符は常に揃える**（#120・ライブでも日常でも）。
    def name
      value = @plain_name ? TrackName.display(field(:name)) : field(:name)
      return TrackName.normalize_marks(value)
    end

    # 表示する名義。⚠ **出さないときは空**（→ `to_s` が行ごと落とす）。
    def credit
      return nil unless @artist
      return field(:artist_name)
    end

    # 表示するアルバム名。⚠ **出さないときは空**（→ `to_s` が行ごと落とす）。
    #
    # ⚠⚠ **列は NULL 可**（母集合では実測 0 件だが、⚠ **収集の版が変われば入りうる**）。
    # 🔴 **空でも行を作らない**（`compact_blank` が落とす）。
    def collection
      return nil unless @collection
      return field(:collection_name)
    end

    # ⚠ **名義より先にアルバム名を置く**（#16）。🔴 **劇伴では、どのシリーズかのほうが
    # 作曲家の名前より先に要る情報。**
    def to_s
      # ⚠ url が無い曲はそもそも母集合から外れている（`TrackRepository#linkable`）が、
      # ここでも空行を作らないようにしておく。
      body = [headline, collection, credit, field(:url)].compact_blank.join("\n")
      # 🔴 **投稿先に本文を再解釈させない**（#270 のレビュー・2026-09-08）。
      # ⚠⚠ **曲名が `#` で始まると、投稿がその名前のタグのタイムラインにも載る**
      # （実データは `#キボウレインボウ#` の 7 行）— ⚠ **MAKOTO が自分で付けるタグは
      # `/live/hashtag` の 1 つだけ**（→ `HashtagSource`）という約束を、**供給元の
      # 曲名が黙って破る**形。
      #
      # 🔴 **組み上げてから当てる。**⚠⚠ **`#` がタグになるかは「本文のどこに居るか」で
      # 決まる**ので、**欄ごとに当てても判定できない**（アルバム名と名義は行頭に来る）。
      # ⚠ **`HashtagSource` が足すタグはこの後なので通らない。**
      #
      # ## ✅ 判定は上流へ返した（#327・2026-09-20）
      #
      # ⚠ **`Makoto::StatusText` を置いていたのは、当時の上流 `escape_status` が
      # `gsub!(/[@#]/, '\0 ')` で `#` `@` を**無条件に全部**置換していたから**
      # （🔴 **`H@ppy Together!!!` が `H@ ppy` に変わる** — 実データは曲名 12 行・
      # アルバム名 8 行がすべてこの形で、**投稿先のメンションに 1 件も当たらない**）。
      #
      # ✅ **`ginseng-fediverse` v3.0.0 が「実際にリンク化する `#` / `@` だけ」に
      # 変わった**（[#273](https://github.com/pooza/ginseng-fediverse/issues/273) /
      # #275）ので、**自前の写しを畳んで上流を呼ぶ。**⚠⚠ **曲データ 14,056 文字列で
      # 実測して差 0 件。**
      #
      # 🔴 **返す先は `escape_status` ではなく `escape_sigils`** — ⚠⚠ **`escape_status`
      # （＝ `sanitize_status`）は HTML の剥がしと `strip` まで含む**ので、**組み上げた
      # 本文に当てると末尾の改行が落ちる**（⚠ **あちらの入口は遠隔のフィード本文**）。
      #
      # ⚠ **判定の正本は上流の `Parser`**（`config/lib.yaml`）に移った — 🔴 **投稿先
      # 1 実装の正規表現をこちらで写さない**（写すと向こうが動いた日に黙ってずれる）。
      return Ginseng::Fediverse::Service.escape_sigils(body)
    end

    private

    # 🔴 **供給元の 1 欄を、本文に使える形で取り出す**（#280）。
    #
    # ⚠ **`Sequel` / SQLite は非 ASCII を ASCII-8BIT で返しうる**（#124 / #79）ので、
    # ⚠⚠ **素で触ると `Encoding::CompatibilityError` になり、`PostingJob#create_text` の
    # `rescue` がその枠を丸ごと落とす**（#280 ＝ #192 で塞いだのと同じ形が、
    # **毎日出る枠に残っていた**）。
    #
    # 🔴 **落ちるのは連結の行とは限らない**（実測）— ⚠⚠ **曲名はいちばん先に
    # `TrackName.normalize_marks` の正規表現で落ちる**ので、**「連結の直前で寄せる」
    # のでは足りない。**⚠ **欄を取り出すところで寄せる。**
    #
    # ⚠ **空の欄は空文字**（→ `to_s` の `compact_blank` が行ごと落とす）。
    def field(key)
      return Text.utf8(@track[key])
    end

    # ⚠⚠ **断りの後ろは 1 行アキ**（#122）。⚠ **断りと曲名が地続きだと、断りが曲名の
    # 一部に見える**（2026-08-19 の当日通しで目視）。
    #
    # ⚠ **改行は設定に書かせない**（`/live/setlist/cover_prefix` は文言だけを持つ）。
    # ⚠⚠ **設定に `\n` を書く形にすると、消したときの壊れ方が分かりにくい。**
    # ⚠ **断りが無いときに先頭が空行にならないこと**（本編の曲）。
    def headline
      return "♪ #{name}" if @prefix.empty?
      return "#{@prefix}\n\n♪ #{name}"
    end
  end
end
