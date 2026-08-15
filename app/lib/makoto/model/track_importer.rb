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

    # ⚠⚠ **供給元が間違えている曲名の訂正表**（#58）。⚠ **表記ゆれとは別物**で、
    # あちらは `dedupe_key` の正規化で吸収する。**誤記は正規化では解けない。**
    #
    # ⚠ **`seed/` に置く**（git 管理下）。⚠⚠ **収集をやり直しても効く**ことが要件で、
    # 収集スクリプトの側を直すと「気づいた順に足す」形が成立しない。
    CORRECTIONS = 'track_corrections.yaml'.freeze

    # 重複判定から落とす文字。⚠ **`duration` は鍵に使えない**（同一曲でも盤に
    # よって 1〜3 秒ばらつく。実測）。正規化した曲名だけで寄せる。
    #
    # ⚠⚠ **`[[:punct:]]` は約物しか落とさない**（Unicode の一般カテゴリ `P*`）。
    # ⚠ **音楽記号は「記号」（`So`）なので素通りする** — `♪` を明示しているのは
    # そのため。⚠⚠ **`♯` `♭` `♮` が漏れていた**（#74）。
    #
    # ⚠ 実害の形: **`#キボウレインボウ#`（U+0023・約物なので落ちる）と
    # `♯キボウレインボウ♯`（U+266F・記号なので残る）が別の曲になる。**
    # ⚠⚠ **公式ですら揺れる表記**なので、訂正表（#58）ではなくここで吸収する。
    # ⚠ **NFKC でも寄らない**（U+266F に互換分解が無い）。
    #
    # ⚠ **音名との衝突（`C♯` と `C`）は理論上ありうるが、`#` 側は既にそうなっている。**
    # 非対称を残すほうが危ない（実データに該当は 0 件）。
    NOISE = /[[:space:][:punct:]♪♯♭♮☆★〜～＋×]/

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
        name = corrected_name(row)
        upsert(:track, {
          id: row[:trackId],
          collection_id: row[:collectionId],
          name: name,
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
          # ⚠ **鍵は訂正後の曲名から作る**（#58）。訂正前で作ると重複がたたまれない。
          dedupe_key: self.class.dedupe_key(name),
        })
      end
    end

    # 訂正表を当てた曲名（→ 上記 `CORRECTIONS`）。
    #
    # ⚠⚠ **`from` が一致したときだけ訂正する。**⚠ **訂正表に無い曲名は 1 文字も
    # 変わらない**（無条件に当てると、供給元が別の誤記に差し替えたときに気付けない）。
    #
    # ⚠ **一致しなくなったら訂正せず、警告を残す。**⚠⚠ **どちらの形でも「この行は
    # 消せる」という同じ合図**なので、黙らせない。**黙ると、消せる行がいつまでも表に残る。**
    #
    # ⚠⚠ **`to` と一致する形（供給元が直した）をとくに黙らせないこと。****上流が直す
    # ときの一番ありふれた形**がこれで、⚠ **ここを素通しにすると片付けの合図が
    # 永久に出ない**（#72 のレビュー指摘）。
    def corrected_name(row)
      name = row[:trackName].to_s
      correction = corrections[row[:trackId]]
      return name unless correction
      return correction[:to] if name == correction[:from]
      logger.warn(track: 'correction', id: row[:trackId], state: correction_state(name, correction),
        expected: correction[:from], actual: name)
      return name
    end

    # ⚠ 消せる理由を分けて残す。**`fixed` なら供給元が直した / `unknown` なら別物に
    # 変わった**（後者は訂正表そのものを見直す）。
    def correction_state(name, correction)
      return 'fixed' if name == correction[:to]
      return 'unknown'
    end

    # ⚠ 訂正表は無くてもよい（あとから足せる）。
    def corrections
      @corrections ||= load_corrections.to_h {|entry| [entry[:id], entry]}
      return @corrections
    end

    def load_corrections
      return [] unless File.exist?(path(CORRECTIONS))
      # ⚠⚠ **`safe_load` を使う**（`noticed: 2026-08-14` は Psych が `Date` にする）。
      return Array(YAML.safe_load_file(path(CORRECTIONS),
        permitted_classes: [Date], symbolize_names: true))
    rescue Psych::Exception => e
      raise Ginseng::ValidateError, "#{CORRECTIONS}: YAML を読めません: #{error_message(e)}"
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
