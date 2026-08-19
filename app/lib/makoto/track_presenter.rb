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
  class TrackPresenter
    # @param track [Hash] `track` テーブルの 1 行
    # @param prefix [String, nil] 曲名の前に置く一言（カバーの断りなど）
    # @param plain_name [Boolean] ⚠ 曲名から括弧書きを落とすか（#119）
    # @param artist [Boolean] ⚠ 名義を出すか（#121）
    def initialize(track, prefix: nil, plain_name: false, artist: true)
      @track = track
      @prefix = prefix.to_s
      @plain_name = plain_name
      @artist = artist
    end

    # 表示する曲名。⚠ **感嘆符・疑問符は常に揃える**（#120・ライブでも日常でも）。
    def name
      value = @plain_name ? TrackName.display(@track[:name]) : @track[:name].to_s
      return TrackName.normalize_marks(value)
    end

    # 表示する名義。⚠ **出さないときは空**（→ `to_s` が行ごと落とす）。
    def credit
      return nil unless @artist
      return @track[:artist_name]
    end

    def to_s
      # ⚠ url が無い曲はそもそも母集合から外れている（`TrackRepository#linkable`）が、
      # ここでも空行を作らないようにしておく。
      return [headline, credit, @track[:url]].compact_blank.join("\n")
    end

    private

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
