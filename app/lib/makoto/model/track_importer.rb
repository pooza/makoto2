module Makoto
  # [seed/](../../../../seed/) の収集物（iTunes Search API・2026-07-29）を SQLite に
  # 投入する。台詞コーパスの投入（`CorpusImporter`）と同じ方針で作ってある。
  #
  # ⚠ **何度実行しても同じ結果になる。**iTunes の `trackId` をそのまま主キーに使い、
  # `INSERT OR REPLACE` で上書きする。**取り込み元に無い行は消さない。**
  #
  # ⚠ **ライブ用は普段用の部分集合**（実測で確認）。普段用を土台に入れて、ライブ用に
  # 出てくる曲へ `live` を立てる。
  #
  # ⚠ **収集スクリプトは Python のまま運用ツールとして残す**（→ docs/CLAUDE.md）。
  # ここは取り込みだけを担う。
  class TrackImporter
    include Package

    # 普段用 4,305 曲。ライブ用 234 曲はこの部分集合。
    DAILY = 'makoto_tracks_daily.json'.freeze
    LIVE = 'makoto_tracks_live.json'.freeze

    # 重複判定から落とす文字。⚠ **`duration` は鍵に使えない**（同一曲でも盤に
    # よって 1〜3 秒ばらつく。実測）。正規化した曲名だけで寄せる。
    NOISE = /[[:space:][:punct:]♪☆★〜～＋×]/

    def initialize(dir = nil, db: Database.connection)
      @dir = dir || File.join(Environment.dir, config['/track/dir'])
      @db = db
    end

    # 曲名を重複判定用の鍵にする。
    #
    # ⚠ **同名で別の曲を潰す危険はある**（サントラのキュー名に「サブタイトル」の
    # ような同名別曲が多い）。それでも、**同一曲が名義違いで何度も出るほうが
    # 実害が大きい**ので、こちらに倒す。
    def self.dedupe_key(name)
      return name.to_s.unicode_normalize(:nfkc).gsub(NOISE, '').downcase
    end

    def exec
      [DAILY, LIVE].each do |file|
        raise Ginseng::NotFoundError, "#{path(file)} not found" unless File.exist?(path(file))
      end
      @db.transaction do
        import_daily
        mark_live
      end
      logger.info(track: 'import', dir: @dir, **counts)
      return counts
    end

    def counts
      tracks = TrackRepository.new(@db)
      return {
        track: tracks.count,
        live: tracks.live.count,
        unique: tracks.dedupe_key_count,
        live_unique: tracks.dedupe_key_count(tracks.live),
      }
    end

    private

    def path(file)
      return File.join(@dir, file)
    end

    def rows(file)
      return JSON.parse(File.read(path(file)), symbolize_names: true)
    end

    def import_daily
      rows(DAILY).each do |row|
        upsert(:track, {
          id: row[:trackId],
          collection_id: row[:collectionId],
          name: row[:trackName],
          artist_name: row[:artistName],
          collection_name: row[:collectionName],
          release_date: release_date(row),
          duration: row[:trackTimeMillis],
          track_number: row[:trackNumber],
          url: row[:trackViewUrl],
          preview_url: row[:previewUrl],
          artwork_url: row[:artworkUrl100],
          kind: row[:kind],
          live: false,
          dedupe_key: self.class.dedupe_key(row[:trackName]),
        })
      end
    end

    # ⚠ **`live` は毎回 false に落としてから立て直す。**ライブ用の定義が変わって
    # 外れた曲に、前回の投入で立てたフラグが残らないようにする。
    def mark_live
      @db[:track].update(live: false)
      ids = rows(LIVE).map {|row| row[:trackId]}
      @db[:track].where(id: ids).update(live: true)
    end

    # iTunes は `2013-05-29T12:00:00Z` の形で返す。日付だけ持てば足りる。
    def release_date(row)
      return nil if row[:releaseDate].blank?
      return Date.parse(row[:releaseDate])
    rescue Date::Error
      # ⚠ 1 曲の日付が壊れていても投入そのものは通す。並べ替え（#13）で後ろに来るだけ。
      logger.warn(track: 'import', id: row[:trackId], release_date: row[:releaseDate])
      return nil
    end

    def upsert(table, values)
      return @db[table].insert_conflict(:replace).insert(values)
    end
  end
end
