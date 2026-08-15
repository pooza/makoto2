module Makoto
  # 曲 1 本ぶんの投稿本文。ライブ（#13）が使い、日常の曲紹介（#16）も同じ形を使う。
  #
  # ⚠⚠ **画像を添付しない。URL を貼って SNS 側のプレビューカードに任せる**
  # （→ docs/CLAUDE.md「画像添付は実装しない」）。⚠ **これは SNS 側の機能なので、
  # 出力先を抽象化しても失われない。**
  #
  # ⚠ **モロヘイヤ経由だと `ItunesImageHandler` が画像も付けて二重になりうる。**
  # #16 で実機確認して、必要ならモロヘイヤ側で切る。
  class TrackPresenter
    # @param track [Hash] `track` テーブルの 1 行
    # @param prefix [String, nil] 曲名の前に置く一言（カバーの断りなど）
    def initialize(track, prefix: nil)
      @track = track
      @prefix = prefix.to_s
    end

    def to_s
      # ⚠ url が無い曲はそもそも母集合から外れている（`TrackRepository#linkable`）が、
      # ここでも空行を作らないようにしておく。
      return [headline, @track[:artist_name], @track[:url]].compact_blank.join("\n")
    end

    private

    def headline
      return "♪ #{@track[:name]}" if @prefix.empty?
      return "#{@prefix}\n♪ #{@track[:name]}"
    end
  end
end
