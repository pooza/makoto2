module Makoto
  # MV のある曲の表（#498）。曲紹介で、音源のリンクの代わりに MV のリンクを出す。
  #
  # ⚠⚠ **収集の経路に乗らない。**🔴 **iTunes の MV は `kind: music-video` でアルバムを持たない**
  # ので、**アルバムの中の `song` を取る `seed/itunes_corpus.py` は拾えない。**⚠ **対象が数本しか
  # 無いので、収集を広げず名指しで書く**（2026-10-05・オーナー判断「そもそも MV が例外的なので、
  # 個別対応で良さそう」）。
  #
  # ## 🔴 表が言うのは事実だけ
  #
  # ⚠ **「この曲には MV がある」と書くだけで、どこで出すかは使う側が決める。**
  # **日常の曲紹介だけが使う**（→ `SongSource#presenter`）。⚠⚠ **ライブは音源のまま**
  # （**11/4 の並びを動かさない**・2026-10-29・オーナー判断）。
  #
  # ## ⚠ 突き合わせは `dedupe_key`
  #
  # 🔴 **語りの表（`SpokenTracks`）と同じ鍵**なので、**盤違いの同じ曲にも効く。**
  #
  # ## ⚠⚠ 常駐の中で凍らせない（#275）
  #
  # 🔴 **メモはインスタンスの中だけ。**⚠ **使う側は枠ごとに作り直す**（→ `Song#music_videos`）。
  class MusicVideos
    include Package

    FILE = 'track_videos.yaml'.freeze

    # @param aliases [TrackAliases] ⚠ **渡さなければ同じディレクトリの別名表を読む**
    def initialize(dir = nil, aliases: nil)
      @dir = dir || File.join(Environment.dir, config['/track/dir'])
      @aliases = aliases
    end

    def path
      return File.join(@dir, FILE)
    end

    # ⚠ **表は無くてもよい**（あとから足せる）。
    def entries
      @entries ||= load_entries
      return @entries
    end

    def names
      return entries.map {|entry| entry[:name]}
    end

    # その曲の MV の URL。⚠ **無ければ nil**（＝音源のまま）。⚠ **`track` は `track` 表の行**。
    def url_for(track)
      return nil unless track
      return urls[track[:dedupe_key].to_s]
    end

    # 🔴 **曲データに 1 行も当たらない名前**（`dedupe_key` の集合を渡す）。
    # ⚠⚠ **配信が終わったか、書き間違えている合図**（語りの表の `spoken: unused` と同じ）。
    def unused(present)
      return names.reject {|name| present.include?(TrackImporter.dedupe_key(name, aliases))}
    end

    def empty?
      return entries.empty?
    end

    private

    def urls
      @urls ||= entries.to_h do |entry|
        [TrackImporter.dedupe_key(entry[:name], aliases), entry[:url]]
      end
      return @urls
    end

    def aliases
      @aliases ||= TrackAliases.new(@dir)
      return @aliases
    end

    def load_entries
      return [] unless File.exist?(path)
      entries = Array(YAML.safe_load_file(path, permitted_classes: [Date], symbolize_names: true))
      return entries.map {|entry| validate(entry)}
    rescue Psych::Exception => e
      raise Ginseng::ValidateError, "#{FILE}: YAML を読めません: #{error_message(e)}"
    end

    # ⚠ **壊れた表で黙って素通ししない。**
    #
    # 🔴 **URL は取り込みと同じ許可リストで見る**（#283 → `TrackUrl`）。
    # ⚠⚠ **曲紹介が 1 日 3 回、永久に公開する URL**なので、**手で書いた表だけ素通しにしない。**
    def validate(entry)
      raise Ginseng::ValidateError, "#{FILE}: 行が Hash ではありません（#{entry.inspect}）" unless
        entry.is_a?(Hash)
      name = entry[:name].to_s
      raise Ginseng::ValidateError, "#{FILE}: name が空の行があります" if name.blank?
      url = entry[:url].to_s
      raise Ginseng::ValidateError, "#{FILE}: #{name} の url を公開できません（#{url.inspect}）" unless
        TrackUrl.public?(url)
      return {name: name, url: url}
    end
  end
end
