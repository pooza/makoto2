module Makoto
  # 旧 DB のダンプ（[tools/pgdump_to_json.py](../../../../tools/pgdump_to_json.py) が
  # 落とした JSON）を SQLite に投入する。
  #
  # ⚠ **何度実行しても同じ結果になること**を保つ。旧 DB の id をそのまま主キーに
  # 使い、`INSERT OR REPLACE` で上書きする。**取り込み元に無い行は消さない**ので、
  # 後から CLI で足した原稿を投入が消すことはない。
  #
  # ⚠ **`account`（393 件）と `fairy`（62 件）は取り込まない。**前者は好感度モデルの
  # ためのアカウント情報で、モデルごと引き継がないと決めている。後者は妖精の語尾で、
  # MAKOTO 本人の口調ではないため 4 機能では使わない。必要になったら別途足す。
  class CorpusImporter
    include Package

    TABLES = ['form', 'series', 'quote', 'message'].freeze

    # 旧 DB の `series.id` → cure-api の key。
    #
    # ⚠ **作品名ではなく id で対応させている。**名前で引くと、このファイルに
    # 作品名を書くことになり、正本が cure-api とこのリポジトリの 2 つに割れる。
    # 劇場版・オールスターズ（id 3〜7）は cure-api の `/series` に無いので
    # 割り当てない（足りない情報は cure-api を伸ばして埋める）。
    CURE_API_KEYS = {1 => 'dokidoki', 2 => 'happiness_charge'}.freeze

    def initialize(dir = nil, db: Database.connection)
      @dir = dir || File.join(Environment.dir, config['/corpus/dir'])
      @db = db
    end

    def exec
      TABLES.each do |table|
        next if File.exist?(path(table))
        raise Ginseng::NotFoundError, "#{path(table)} not found"
      end
      @db.transaction do
        import_forms
        import_series
        import_quotes
        import_messages
      end
      logger.info(corpus: 'import', dir: @dir, **counts)
      return counts
    end

    def counts
      return {
        form: @db[:form].count,
        series: @db[:series].count,
        quote: @db[:quote].count,
        respondable: QuoteRepository.new(@db).respondable_count,
        message: @db[:message].count,
        message_season: @db[:message_season].count,
      }
    end

    private

    def path(table)
      return File.join(@dir, "#{table}.json")
    end

    def rows(table)
      return JSON.parse(File.read(path(table)), symbolize_names: true)
    end

    def import_forms
      rows('form').each do |row|
        upsert(:form, id: row[:id], name: row[:name])
      end
    end

    def import_series
      rows('series').each do |row|
        upsert(:series, id: row[:id], name: row[:name], cure_api_key: CURE_API_KEYS[row[:id]])
      end
    end

    def import_quotes
      rows('quote').each do |row|
        upsert(:quote, {
          id: row[:id],
          series_id: row[:series_id],
          form_id: row[:form_id],
          episode: row[:episode],
          emotion: row[:emotion],
          exclude: row[:exclude],
          exclude_respond: row[:exclude_respond],
          priority: row[:priority],
          body: row[:body],
          remark: row[:remark],
        })
      end
    end

    def import_messages
      rows('message').each do |row|
        upsert(:message, {
          id: row[:id],
          type: row[:type],
          feature: row[:feature],
          body: row[:message],
          month: row[:month],
          day: row[:day],
        })
        import_seasons(row)
      end
    end

    # `message.data` は `'{"season": [6,7,8]}'` という json 文字列。月ごとの行に
    # 展開する。**入れ直す前に消す**ので、取り込み元で季節が減っても残らない。
    def import_seasons(row)
      @db[:message_season].where(message_id: row[:id]).delete
      seasons(row).each do |month|
        upsert(:message_season, message_id: row[:id], month: month)
      end
    end

    def seasons(row)
      return [] if row[:data].blank?
      data = JSON.parse(row[:data])
      return Array(data['season']).map(&:to_i)
    rescue JSON::ParserError => e
      raise Ginseng::ValidateError, "message #{row[:id]} has broken data (#{error_message(e)})"
    end

    def upsert(table, values)
      return @db[table].insert_conflict(:replace).insert(values)
    end
  end
end
