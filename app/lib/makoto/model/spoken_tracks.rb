module Makoto
  # 歌ではなく語りのトラックの表（#298）。ボイスドラマ・朗読劇・トーク。
  #
  # ⚠⚠ **供給元の `kind` では分からない。**🔴 **iTunes は歌と同じ `vocal` で返す**ので、
  # **#293 の種類別の前置き（`song_vocal`）がドラマに付きうる**（「思わず口ずさんじゃう」）。
  #
  # 🔴 **だから名指しで書く表にする**（訂正表 #58・別名表 #123 と同じ形）。
  # ⚠ **新しい `kind` には分けない** — **抽選の重みは `kind` ごと**なので、**3 曲しかない
  # `kind` が 5.9% 出てしまう**（→ [track-corpus.md](../../../../docs/track-corpus.md)）。
  # ⚠ **尺で切らない** — **普通の長い曲（メドレー・劇伴）を巻き込む**うえ、曲データが
  # 増えると基準がずれる（#294）。
  #
  # ## 🔴 表が言うのは事実だけ
  #
  # ⚠ **「語りのトラックだ」と書くだけで、どう扱うかは使う側が決める。**曲紹介は
  # **共通の前置きだけ**を付ける（→ `SongSource#compose`）。
  #
  # ## ⚠ 突き合わせは `dedupe_key`
  #
  # 🔴 **同じ曲が盤違いで複数行ある**ので、`trackId` だと取りこぼしうる（⚠ **抽選の代表が
  # どの盤になるかは `TrackRepository#distinct` 次第**）。⚠ **履歴（#41）と同じ鍵。**
  #
  # ## ⚠⚠ 常駐の中で凍らせない（#275）
  #
  # 🔴 **メモはインスタンスの中だけ。**⚠ **使う側は枠ごとに作り直す**（→ `Song#spoken_tracks`）
  # — ⚠⚠ **別名表はクラスでメモしたせいで、常駐が起動したときの表のまま凍った。**
  # ⚠ **別名表もここでは作り直す**（`TrackImporter.default_aliases` を使わない）。
  class SpokenTracks
    include Package

    FILE = 'track_spoken.yaml'.freeze

    # @param aliases [TrackAliases] ⚠ **渡さなければ同じディレクトリの別名表を読む**
    def initialize(dir = nil, aliases: nil)
      @dir = dir || File.join(Environment.dir, config['/track/dir'])
      @aliases = aliases
    end

    def path
      return File.join(@dir, FILE)
    end

    # ⚠ **表は無くてもよい**（あとから足せる）。
    def names
      @names ||= load_names
      return @names
    end

    # 表の曲名を `dedupe_key` にしたもの。
    def keys
      @keys ||= names.to_set {|name| TrackImporter.dedupe_key(name, aliases)}
      return @keys
    end

    # その曲が語りのトラックか。⚠ **`track` は `track` 表の行**（`dedupe_key` を持つ）。
    def include?(track)
      return false unless track
      return keys.include?(track[:dedupe_key].to_s)
    end

    # 🔴 **曲データに 1 行も当たらない名前**（`dedupe_key` の集合を渡す）。
    # ⚠⚠ **配信が終わったか、書き間違えている合図**（別名表の `alias: unused` と同じ）。
    def unused(present)
      return names.reject {|name| present.include?(TrackImporter.dedupe_key(name, aliases))}
    end

    def empty?
      return names.empty?
    end

    private

    def aliases
      @aliases ||= TrackAliases.new(@dir)
      return @aliases
    end

    def load_names
      return [] unless File.exist?(path)
      entries = Array(YAML.safe_load_file(path, permitted_classes: [Date], symbolize_names: true))
      return entries.map {|entry| validate(entry)}
    rescue Psych::Exception => e
      raise Ginseng::ValidateError, "#{FILE}: YAML を読めません: #{error_message(e)}"
    end

    # ⚠ **壊れた表で黙って素通ししない。**🔴 **`name` の無い行は何にも当たらない**ので、
    # ⚠⚠ **書いたのに効いていないことに気づけない形になる。**
    def validate(entry)
      raise Ginseng::ValidateError, "#{FILE}: 行が Hash ではありません（#{entry.inspect}）" unless
        entry.is_a?(Hash)
      name = entry[:name].to_s
      raise Ginseng::ValidateError, "#{FILE}: name が空の行があります" if name.blank?
      return name
    end
  end
end
