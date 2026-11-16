module Makoto
  # 会話に出てきた曲の名義を、曲データで引いて渡す（#668）。→ `ChatModel#song_blocks`
  #
  # ## 🔴 利用者の投稿に書かれた名義は欠けていることがある
  #
  # nowplaying の投稿（`Title:` / `Artist:` の行）は、OS のメディア情報から名義を取る。⚠⚠ **Linux 版 Spotify は
  # MPRIS に 1 人目しか入れない**（2026-11-14 実測 →  #668）。「HEART GOES ON / Artist: 工藤真由」を見た真琴が、
  # 池田彩さんとのデュエットを工藤真由さんひとりの歌として話した。
  #
  # ⚠ 道具（`search_songs`）はあるが、**呼ぶかどうかはモデルが決める**ので、書かれた名義を確かめずに使った。
  # ここでは**モデルに任せず、送る側で引いて渡す**（#668 の案 B・食い違いを確実に示せる）。
  #
  # ## 🔴 名義を断定するのは、食い違いがはっきりしたときだけ
  #
  # - 曲名（`Title:`）を曲データの鍵（`TrackImporter.dedupe_key`）で引き、歌の曲（`ChatTools::SONG_KINDS`）だけを見る
  # - 投稿に名義（`Artist:`）が無ければ、曲データの名義が 1 つに決まるときだけ渡す
  # - 投稿に名義があれば、それを**含む**曲データの名義がちょうど 1 つのときだけ「欠けている」と渡す。⚠ 同じなら
  #   何も渡さない。⚠ 含むものが無い・2 つ以上（同名の別の歌）なら渡さない（表記の違いを誤りと取らない）
  #
  # ⚠⚠ **曲名も名義もログに出さない**（相手の投稿の一部）。件数だけ。
  class ChatSongFacts
    include Package

    TITLE = /^Title:[ \t]*(.+?)[ \t]*$/
    ARTIST = /^Artist:[ \t]*(.+?)[ \t]*$/
    # 1 回の返事で引く曲の上限（費用の歯止め・ふつうは 1 曲）。
    MAX_TITLES = 3
    LEAD = '会話に出てきた曲を、送る側が曲データで引いたもの。歌った人の名前は、こちらに従う。'.freeze
    # 🔴 **正すのではなく、歌った人を全員呼びたい敬意として触れる**（#668 のオーナーの補足）。
    MISSING = '投稿の名義が欠けているときは、歌った人を全員ちゃんと呼びたい気持ちとして、あなたのほうから全員の名前に触れる' \
      '（例:「このお歌は〇〇さんと△△さん、おふたりの声ですね」）。相手を正す口調にしない。'.freeze

    Fact = Data.define(:title, :artist, :posted)

    # @param tracks [TrackRepository, nil] ⚠ テストが差し替える
    def initialize(tracks: nil)
      @tracks = tracks
    end

    # @param messages [Array<Hash>] `{role:, content:}` の並び（→ `ChatThread#messages`）
    # @return [String, nil] ⚠ **渡すものが無ければ nil**
    def to_prompt(messages)
      facts = facts_of(messages)
      return nil if facts.empty?
      lines = ['## 話題の曲の名義（曲データ）', '', LEAD, '']
      facts.each {|fact| lines.push(line(fact))}
      lines.push('', MISSING) if facts.any?(&:posted)
      return lines.join("\n")
    rescue => e
      # 🔴 **引けなくても返事は止めない**（名義を渡さないだけ）。
      logger.warn(chat: 'song_facts', message: 'failed', error_class: e.class.name)
      report_error(e, chat: 'song_facts')
      return nil
    end

    # @return [Array<Fact>]
    def facts_of(messages)
      pairs = messages.flat_map {|message| pairs_of(message[:content].to_s)}
      pairs = pairs.uniq {|title, _| TrackImporter.dedupe_key(title)}.first(MAX_TITLES)
      facts = pairs.filter_map {|title, posted| fact(title, posted)}
      logger.info(chat: 'song_facts', titles: pairs.size, facts: facts.size) if pairs.any?
      return facts
    end

    def self.normalize_artist(name)
      return name.to_s.unicode_normalize(:nfkc).gsub(/[[:space:]]/, '').downcase
    end

    private

    # `Title:` の行と、その後ろ（次の `Title:` の前）にある最初の `Artist:` の行の組。
    def pairs_of(text)
      pairs = []
      text.each_line do |row|
        if (title = row[TITLE, 1])
          pairs.push([title, nil])
        elsif (artist = row[ARTIST, 1]) && pairs.last && pairs.last[1].nil?
          pairs.last[1] = artist
        end
      end
      return pairs
    end

    def fact(title, posted)
      artists = artists_of(title)
      return nil if artists.empty?
      unless posted
        return artists.size == 1 ? Fact.new(title:, artist: artists.values.first, posted: nil) : nil
      end
      key = self.class.normalize_artist(posted)
      return nil if artists.key?(key)
      candidates = artists.select {|name, _| name.include?(key)}
      return nil unless candidates.size == 1
      return Fact.new(title:, artist: candidates.values.first, posted:)
    end

    # 正規化した名義 => 表示する名義（新しい盤のもの）。
    def artists_of(title)
      rows = tracks.dataset
        .where(kind: ChatTools::SONG_KINDS, dedupe_key: TrackImporter.dedupe_key(title))
        .reverse(:release_date, :id).all
      return rows.each_with_object({}) do |row, artists|
        artists[self.class.normalize_artist(row[:artist_name])] ||= row[:artist_name]
      end
    end

    def line(fact)
      text = "- 「#{fact.title}」: #{fact.artist}"
      text += "（投稿の「Artist: #{fact.posted}」は名義が欠けている）" if fact.posted
      return text
    end

    def tracks
      return @tracks ||= TrackRepository.new
    end
  end
end
