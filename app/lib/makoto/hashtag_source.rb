module Makoto
  # 本文の最終行にハッシュタグを足す `PostingJob` の `source`（#64）。
  #
  # ⚠⚠ **最終行をハッシュタグだけの行にする。**モロヘイヤがその形を処理するため
  # （→ docs/CLAUDE.md「リハーサルを見て決めた微調整」）。本文の末尾に続けて
  # 書かない。
  #
  # ⚠ **原稿の側に書き足さない。**告知や MC は原稿なので YAML に書けば入るが、
  # **曲の投稿は原稿ではない**（`TrackPresenter` が組む）。⚠ 原稿側に手で書くと
  # **曲だけタグが付かないか、原稿の書き忘れが出る**ので、ライブの枠すべてを
  # ここで包む。
  #
  # ⚠⚠ **本文が無いときはタグも出さない。**`source` が nil を返すのは「その枠は
  # 投稿しない」という合図（原稿が無い日・ライブ当日でない日）。⚠ ここでタグを
  # 足すと**タグだけの投稿が毎日出る。**
  class HashtagSource
    include Package

    # @param source [#call] 包む `source`
    # @param hashtag [String, nil] 足すハッシュタグ。⚠ **空なら何もしない**
    def initialize(source:, hashtag: nil)
      @source = source
      @hashtag = hashtag.to_s.strip
    end

    def call(time = nil)
      text = @source.call(time)
      return text if text.to_s.strip.empty?
      return text if @hashtag.empty?
      return [text.to_s.rstrip, @hashtag].join("\n")
    end
  end
end
