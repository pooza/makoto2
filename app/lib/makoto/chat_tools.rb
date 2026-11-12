module Makoto
  # チャットボットが返事の途中で引く道具（#623）。⚠ **呼ぶかどうかはモデルが決める**（→ `ChatModel`）。
  #
  # ## 🔴 持たせるのは 2 つだけ（2026-11-13）
  #
  # | 道具 | 引く先 | 返すもの |
  # | --- | --- | --- |
  # | `search_songs` | makoto2 の曲データ（曲紹介の母集団と同じ） | 曲名・名義・収録盤・発売日（新しい順） |
  # | `lookup_precure` | cure-api の `/girls` | プリキュアの名前・変身前の名前・声優 |
  #
  # ⚠ **少ないほど誤用が減る**ので、作品を引く道具は持たせない — cure-api の `/series` は作品名しか返さず
  # （放送期間・登場するプリキュアが無い・2026-11-13 実測）、引いても答えの足しにならない。
  # 🔴 **ドキプリは本人の記憶として持つ**（指示書・台帳）。この道具はドキプリ以外を話すためのもの（#623 のオーナーの整理）。
  #
  # ## 🔴 失敗しても例外を上げない
  #
  # 引けなければ `Result#error?` で返し、モデルには「引けなかった」と伝える（`is_error`）。⚠ 返事は止めない —
  # 指示書が「引いて分かった範囲でだけ話す」と決めているので、引けなければ曲名を挙げずにかわす。
  #
  # ⚠⚠ **引いた語も結果もログに出さない**（相手の投稿の一部になりうる）。道具の名前と件数だけ。
  class ChatTools
    include Package

    # ⚠ 歌の曲だけ（劇伴・カラオケ・インストは「お勧めの曲」にならない）。
    SONG_KINDS = ['vocal', 'tv_size'].freeze
    SONG_LIMIT = 8
    PRECURE_LIMIT = 5
    # cure-api の `/girls` を引き直す間隔。⚠ 100 人ほどで変わるのは新番組のときだけ。
    GIRLS_TTL = 24 * 60 * 60
    # `/girls` のうち、名前で当てる列。
    GIRL_NAME_KEYS = ['precure_name', 'human_name', 'cast_name'].freeze

    DEFINITIONS = [
      {
        name: 'search_songs',
        description: <<~TEXT.strip,
          プリキュアの歌の曲データ（配信されている歌）を引く。新しい順に最大 #{SONG_LIMIT} 曲を返す。
          曲名・歌手名・収録盤のどれかに含まれる語で絞れる。語を空にすると、いちばん新しい曲から返す。
          最近の曲やお勧めの曲を訊かれたとき、知らない曲名を確かめたいときに使う。
        TEXT
        input_schema: {
          type: 'object',
          properties: {
            query: {type: 'string', description: '曲名・歌手名・収録盤に含まれる語（空なら新しい順）'},
          },
          required: ['query'],
          additionalProperties: false,
        },
        strict: true,
      },
      {
        name: 'lookup_precure',
        description: <<~TEXT.strip,
          プリキュアを名前で引く（キュアの名前・変身前の名前・声優の名前のどれか）。最大 #{PRECURE_LIMIT} 人。
          他の作品のプリキュアの名前や声優を確かめたいときに使う。
        TEXT
        input_schema: {
          type: 'object',
          properties: {
            query: {type: 'string', description: 'キュアの名前・変身前の名前・声優の名前の一部'},
          },
          required: ['query'],
          additionalProperties: false,
        },
        strict: true,
      },
    ].freeze

    Result = Data.define(:content, :count, :error) do
      def error?
        return !error.nil?
      end
    end

    # @param tracks [TrackRepository, nil] ⚠ テストが差し替える
    # @param http [HTTP, nil] ⚠ テストが差し替える
    def initialize(tracks: nil, http: nil)
      @tracks = tracks
      @http = http
      @girls = nil
      @girls_at = nil
    end

    # @return [Result] ⚠ **例外を上げない**（→ クラスの冒頭）
    def call(name, input)
      query = input.is_a?(Hash) ? (input['query'] || input[:query]).to_s.strip : ''
      case name.to_s
      when 'search_songs' then return found(search_songs(query))
      when 'lookup_precure' then return found(lookup_precure(query))
      else return failed("unknown tool: #{name}")
      end
    rescue => e
      logger.warn(chat: 'tool', tool: name.to_s, message: 'failed', error_class: e.class.name)
      report_error(e, chat: 'tool', tool: name.to_s)
      return failed('引けませんでした')
    end

    def search_songs(query)
      records = tracks.dataset.where(kind: SONG_KINDS)
      unless query.empty?
        pattern = "%#{escape_like(query)}%"
        records = records.where(
          Sequel.ilike(:name, pattern) | Sequel.ilike(:artist_name, pattern) |
          Sequel.ilike(:collection_name, pattern),
        )
      end
      rows = records.reverse(:release_date, :id).limit(SONG_LIMIT * 5).all
      rows = rows.uniq {|row| row[:dedupe_key]}.first(SONG_LIMIT)
      return rows.map do |row|
        {
          title: row[:name],
          artist: row[:artist_name],
          album: row[:collection_name],
          released: row[:release_date]&.to_s,
        }
      end
    end

    def lookup_precure(query)
      return [] if query.empty?
      needle = CureApiService.normalize(query)
      hits = girls.select do |girl|
        GIRL_NAME_KEYS.any? do |key|
          CureApiService.normalize(girl[key].to_s).delete(' ').include?(needle.delete(' '))
        end
      end
      return hits.first(PRECURE_LIMIT).map do |girl|
        {
          precure: girl['precure_name'],
          name: girl['human_name'],
          cast: girl['cast_name'],
        }
      end
    end

    private

    def found(rows)
      return Result.new(content: JSON.generate(rows), count: rows.size, error: nil)
    end

    def failed(message)
      return Result.new(content: message, count: 0, error: message)
    end

    # ⚠ **引けたときだけ覚える**（失敗を覚えると、不通が常駐の寿命ぶん続く → `CureApiService#singer_names`）。
    def girls
      return @girls if @girls && @girls_at && (Time.now - @girls_at) < GIRLS_TTL
      url = config['/cure_api/url'].to_s
      raise Ginseng::ConfigError, '/cure_api/url is missing' if url.empty?
      records = http.get("#{url}/girls").parsed_response
      unless records.is_a?(Array) && records.all?(Hash)
        raise Ginseng::GatewayError, 'cure-api: unexpected /girls'
      end
      @girls_at = Time.now
      return @girls = records
    end

    def escape_like(value)
      return value.gsub(/[\\%_]/) {|char| "\\#{char}"}
    end

    def tracks
      return @tracks ||= TrackRepository.new
    end

    def http
      return @http ||= HTTP.new
    end
  end
end
