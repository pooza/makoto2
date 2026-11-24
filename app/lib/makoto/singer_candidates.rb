module Makoto
  # 歌手辞書（cure-api の `/singers`）に当たらない名義を、曲データから抜き出す（#565）。→ `makoto track singers`
  #
  # 月 1 回の曲データの収集（#294）で反映するときに回し、プリキュア歌手として辞書へ載せるものを選ぶ材料にする。
  # 🔴 **選んで載せるのは人**（最初の何回かはオーナーに一覧を見せる・2026-11-17）。ここは一覧を出すだけ。
  #
  # ## 分け方
  #
  # | 分類 | 当てはまるもの | 例 |
  # | --- | --- | --- |
  # | `title` | 作品名（「プリキュア」を含む・「映画」で始まる） | `ひろがるスカイ!プリキュア` |
  # | `character` | キャラクター名義（括弧の注記つき・cure-api の `/girls` の名前） | `キュアミラクル(CV:高橋李依)` / `つぼみ` |
  # | `candidate` | それ以外（作家・非プリキュア歌手・新しいプリキュア歌手） | `高橋秀幸` |
  #
  # ⚠⚠ **名義を割るのは、この一覧のためだけ**（人が読む候補）。数える側（`CureApiService#credit_count`）は割らない
  # 約束のまま（#157）。⚠ **括弧の中は割らず、辞書の名前も消さない**（`剣崎真琴(CV:宮本佳那子)` を 1 つのまま残す）。
  # ⚠ コーラス区画は先に落とす（`OwnCredit::CHORUS`）。
  class SingerCandidates
    include Package

    Candidate = Data.define(:name, :kind, :count, :example)

    BRACKET = /[(（\[「『〈][^)）\]」』〉]*[)）\]」』〉]/
    ONLY_BRACKETS = /\A(?:#{BRACKET})+\z/
    # ⚠ `with` / `feat` の前後は `\b` にしない（正規化で空白が詰まり、`withヤング` の境目を `\b` は見ない・#727）。
    SEPARATOR = %r{[,、&＆/／・･〜~]|(?<![a-z])with(?![a-z])|(?<![a-z])feat(?![a-z])\.?}i
    TITLE = /プリキュア|ぷりきゅあ|\A映画/i
    KINDS = ['candidate', 'character', 'title'].freeze

    # @param tracks [TrackRepository, nil] ⚠ テストが差し替える
    # @param singers [Array<String>, nil] 歌手辞書の名前（正規化済み）。⚠ テストが差し替える
    # @param girls [Array<Hash>, nil] cure-api の `/girls`。⚠ テストが差し替える
    def initialize(tracks: nil, singers: nil, girls: nil)
      @tracks = tracks
      @singers = singers
      @girls = girls
    end

    # @return [Array<Candidate>] 分類ごと（候補 → キャラクター名義 → 作品名）・曲数の多い順
    def exec
      found = {}
      counted = Set.new
      songs.each do |row|
        names_of(row[:artist_name]).each do |name|
          # ⚠ 同じ名前の同じ曲は 1 回（同じ名義に 2 度書かれた名前・名義の書き方違い・#727）。
          next unless counted.add?([name, row[:dedupe_key]])
          found[name] ||= {count: 0, example: row[:name]}
          found[name][:count] += 1
        end
      end
      candidates = found.map {|name, entry| Candidate.new(name:, kind: kind_of(name), **entry)}
      return candidates.sort_by {|item| [KINDS.index(item.kind), -item.count, item.name]}
    end

    # 名義のうち、辞書に当たらない名前。
    def names_of(artist)
      # ⚠ 括弧は私用領域の印に置き換えておく（`String#strip` は NUL も落とすので NUL にしない）。
      brackets = []
      text = CureApiService.normalize(artist).gsub(OwnCredit::CHORUS, '').gsub(BRACKET) do |found|
        brackets.push(found)
        "\uE000#{brackets.size - 1}\uE001"
      end
      dictionary.each {|name| text = text.gsub(name, ' ') if text.include?(name)}
      return text.split(SEPARATOR).filter_map do |part|
        part = part.strip.gsub(/\uE000(\d+)\uE001/) {brackets[Regexp.last_match(1).to_i]}
        # ⚠ 辞書の名前の後ろに残った括弧（構成員の注記・空の括弧）だけの欠片は捨てる。
        next if part.empty? || part.match?(ONLY_BRACKETS)
        part
      end
    end

    def kind_of(name)
      return 'title' if name.match?(TITLE) && !name.match?(BRACKET)
      return 'character' if name.match?(BRACKET) || girl_names.include?(name)
      return 'candidate'
    end

    private

    # 歌の曲を、同じ名義の同じ曲は 1 回に数える（盤違いで水増ししない）。
    def songs
      rows = tracks.dataset.where(kind: ChatTools::SONG_KINDS)
      rows = rows.select(:name, :artist_name, :dedupe_key).all
      return rows.uniq {|row| [row[:artist_name], row[:dedupe_key]]}
    end

    # ⚠ **長い名前から消す**（`キュア・カルテット` を構成員より先に・→ `CureApiService#credit_count`）。
    def dictionary
      return @dictionary if @dictionary
      names = @singers || CureApiService.new.singer_names
      return @dictionary = names.sort_by {|name| [-name.size, name]}
    end

    # プリキュアの名前・変身前の名前・下の名前（`花咲 つぼみ` の `つぼみ`）。
    # ⚠ 引けなければ空（分け方が粗くなるだけ）。
    def girl_names
      return @girl_names if @girl_names
      names = girls.flat_map do |girl|
        human = girl['human_name'].to_s
        [girl['precure_name'], human, human.split(/[[:space:]]+/).last]
      end
      return @girl_names = names.map {|name| CureApiService.normalize(name)}.reject(&:empty?).to_set
    end

    def girls
      return @girls if @girls
      records = HTTP.new.get("#{config['/cure_api/url']}/girls").parsed_response
      return @girls = records.is_a?(Array) ? records.grep(Hash) : []
    rescue => e
      logger.warn(singers: 'candidates', message: 'girls unavailable', error_class: e.class.name)
      return @girls = []
    end

    def tracks
      return @tracks ||= TrackRepository.new
    end
  end
end
