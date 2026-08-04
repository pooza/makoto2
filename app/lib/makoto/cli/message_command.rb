module Makoto
  # 原稿の運用操作。⚠ **原稿の追加がコード変更なしでできること**が #12 の完了条件で、
  # 管理コンソールを作らない決定の帰結として入口はここ（→ docs/CLAUDE.md）。
  class MessageCommand < Thor
    include Package

    # 朝挨拶（#17）が使う既定の許可リスト。⚠ `template` / `calling` は全件が `%s` を
    # 含む穴埋めテンプレートなので入れない（そのまま投稿すると `%s` が出る）。
    DEFAULT_TYPES = ['holiday', 'birthday', 'morning'].freeze

    def self.exit_on_failure?
      return true
    end

    option :type, type: :string, required: true, desc: 'morning / holiday / birthday / 台本の type'
    option :date, type: :string, desc: '特定日。MM-DD（毎年）または YYYY-MM-DD（その年だけ）'
    option :season, type: :string, desc: '季節。月をカンマ区切りで（例: 9,10）'
    option :feature, type: :string, desc: '人手のメタ情報（任意）'
    desc 'add BODY', '原稿を足す'
    def add(body)
      date = parse_date(options[:date])
      id = MessageRepository.new.create(
        type: options[:type],
        body: body,
        year: date[:year],
        month: date[:month],
        day: date[:day],
        feature: options[:feature],
        seasons: parse_season(options[:season]),
      )
      puts "id: #{id}"
    rescue Ginseng::ValidateError => e
      warn error_message(e)
      exit 1
    rescue Sequel::DatabaseError => e
      warn "足せませんでした。先に `rake migration:run` を実行してください: #{error_message(e)}"
      exit 1
    end

    option :type, type: :string, desc: 'type で絞る'
    option :limit, type: :numeric, default: 20, desc: '表示する件数'
    desc 'list', '原稿を一覧する'
    def list
      repository = MessageRepository.new
      records = options[:type] ? repository.by_type(options[:type]) : repository.dataset
      records.order(:id).limit(options[:limit]).each do |row|
        puts "[#{row[:id]}] #{row[:type]} #{format_date(row)} #{summary(row[:body])}"
      end
      puts "(#{records.count} 件)"
    rescue Sequel::DatabaseError => e
      warn "読めませんでした。先に `rake migration:run` を実行してください: #{error_message(e)}"
      exit 1
    end

    desc 'remove ID', '原稿を消す'
    def remove(id)
      repository = MessageRepository.new
      row = repository.dataset[id: id.to_i]
      unless row
        warn "原稿 #{id} はありません"
        exit 1
      end
      repository.delete(row[:id])
      puts "消しました: [#{row[:id]}] #{row[:type]} #{summary(row[:body])}"
    end

    option :date, type: :string, desc: '下見する日付（既定は今日）。YYYY-MM-DD'
    option :types, type: :string, desc: "使ってよい type をカンマ区切りで（既定は #{DEFAULT_TYPES.join(',')}）"
    desc 'preview', 'その日に選ばれる原稿を表示する（投稿はしない）'
    def preview
      selector = MessageSelector.new(options[:types]&.split(',') || DEFAULT_TYPES)
      message = selector.find(preview_date(options[:date]))
      unless message
        puts '原稿はありません（通常の生成にフォールバックします）'
        return
      end
      puts "[#{message[:id]}] #{message[:type]} #{format_date(message)}"
      puts message[:body]
    rescue Ginseng::ValidateError => e
      warn error_message(e)
      exit 1
    end

    private

    # 'MM-DD'（毎年）と 'YYYY-MM-DD'（その年だけ）の両方を受ける。
    def parse_date(value)
      return {year: nil, month: nil, day: nil} if value.blank?
      if (matches = value.match(/\A(\d{4})-(\d{2})-(\d{2})\z/))
        return {year: matches[1].to_i, month: matches[2].to_i, day: matches[3].to_i}
      end
      if (matches = value.match(/\A(\d{1,2})-(\d{1,2})\z/))
        return {year: nil, month: matches[1].to_i, day: matches[2].to_i}
      end
      raise Ginseng::ValidateError, "日付は MM-DD か YYYY-MM-DD で指定してください（'#{value}'）"
    end

    def parse_season(value)
      return [] if value.blank?
      months = value.split(',').map {|month| month.strip.to_i}
      unless months.all? {|month| month.between?(1, 12)}
        raise Ginseng::ValidateError, "季節は 1〜12 の月で指定してください（'#{value}'）"
      end
      return months
    end

    # ⚠⚠ **日付のまま渡す。**時刻を作るとホストの TZ で解釈され、`/scheduler/timezone`
    # に直したときに 1 日ずれる（日本の外で下見すると 11/4 が 11/5 になる）。
    def preview_date(value)
      return nil if value.blank?
      return Date.parse(value)
    rescue Date::Error
      raise Ginseng::ValidateError, "日付は YYYY-MM-DD で指定してください（'#{value}'）"
    end

    # ⚠ 季節指定を「通年」と表示しない。**季節の原稿は通年で回すものではない**ので、
    # 区別が付かないと下見の意味が無くなる。
    def format_date(row)
      if row[:month]
        return '%{year}%<month>02d-%<day>02d' % {year: row[:year] ? "#{row[:year]}-" : '',
          month: row[:month],
          day: row[:day]}
      end
      seasons = MessageRepository.new.seasons(row[:id])
      return '(通年)' if seasons.empty?
      return "(季節: #{seasons.join(',')} 月)"
    end

    def summary(body)
      text = body.to_s.gsub("\n", ' / ')
      return text if text.length <= 40
      return "#{text[0, 40]}…"
    end
  end
end
