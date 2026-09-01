module Makoto
  # 原稿の運用操作。⚠ **原稿の追加がコード変更なしでできること**が #12 の完了条件で、
  # 管理コンソールを作らない決定の帰結として入口はここ（→ docs/CLAUDE.md）。
  class MessageCommand < Thor
    include Package

    # 朝挨拶（#17）が使う既定の許可リスト。⚠ `template` / `calling` は全件が `%s` を
    # 含む穴埋めテンプレートなので入れない（そのまま投稿すると `%s` が出る）。
    # ⚠ `birthday` は入らない（#60 で落とした。用途はライブの台本が吸収した）。
    DEFAULT_TYPES = ['holiday', 'morning'].freeze

    def self.exit_on_failure?
      return true
    end

    option :type, type: :string, required: true, desc: 'morning / holiday / 台本の type'
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

    option :prune, type: :boolean, default: false,
      desc: '⚠ 取り込み元から消えた原稿を落とす。取り込み元の全体を指すときだけ使う'
    option :dry_run, type: :boolean, default: false, desc: '書き込まずに、何が起きるかだけ表示する'
    desc 'import PATH', 'ファイル（またはディレクトリ）から原稿を取り込む'
    def import(path)
      importer = ScriptImporter.new
      return preview_import(importer, path) if options[:dry_run]
      result = importer.import(path, prune: options[:prune])
      puts result
      result.pruned&.each {|slug| puts "削除: #{slug}"}
    rescue Ginseng::ValidateError => e
      warn error_message(e)
      exit 1
    rescue Sequel::DatabaseError => e
      warn "取り込めませんでした。先に `rake migration:run` を実行してください: #{error_message(e)}"
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

    option :type, type: :string, required: true, desc: '書き出す type をカンマ区切りで'
    option :out, type: :string, required: true, desc: '書き出すファイル（YAML）'
    option :prefix, type: :string, desc: 'slug の接頭辞（既定は type）'
    option :exclude, type: :string, desc: '書き出さない id をカンマ区切りで'
    option :force, type: :boolean, default: false, desc: '既にあるファイルを上書きする'
    desc 'export', '原稿を取り込みの形式（YAML）で書き出す'
    def export
      # 🔴 **本文をこのリポジトリに出さない**（public。→ docs/CLAUDE.md の情報の記載先）。
      # ⚠⚠ **標準出力にも出さない** — **書き出し先はファイルだけ**にして、
      # ⚠ **原稿がログや貼り付けに紛れ込む経路を作らない。**
      path = options[:out]
      if File.exist?(path) && !options[:force]
        warn "#{path} は既にあります（上書きするなら --force）"
        exit 1
      end
      records = export_records(options[:type].split(','), exclude_ids(options[:exclude]))
      File.write(path, export_header(records) + records.to_yaml)
      puts "#{records.size} 件を #{path} へ書き出しました"
    rescue Ginseng::ValidateError => e
      warn error_message(e)
      exit 1
    end

    private

    # ⚠ **`slug` を持つ行はその `slug` を保つ**（⚠⚠ **付け直すと取り込みで二重になる**）。
    # ⚠ **持たない行には `接頭辞-通し番号` を振る。**番号は id 順で安定させる。
    def export_records(types, excluded)
      rows = types.flat_map {|type| repository.by_type(type.strip).order(:id).all}
      rows = rows.reject {|row| excluded.include?(row[:id])}
      # 🔴 **既にある `slug` と衝突させない**（#224・Codex の P2）。⚠⚠ **持っている行の
      # `slug` を保つ**ので、⚠ **通し番号がその `slug` と同じ値を作りうる** —
      # **同じ `slug` が 2 つあるファイルは取り込みが弾く**（`ScriptImporter#read`）。
      taken = repository.by_slug.select_map(:slug).to_set
      counter = 0
      rows.map do |row|
        slug = row[:slug]
        slug, counter = next_slug(options[:prefix] || row[:type], taken, counter) unless slug
        export_record(row, slug)
      end
    end

    # 空いている通し番号の `slug`。⚠ **番号は id 順に振る**（並びが安定する）。
    def next_slug(prefix, taken, counter)
      loop do
        counter += 1
        slug = '%{prefix}-%<counter>04d' % {prefix: prefix, counter: counter}
        next if taken.include?(slug)
        taken.add(slug)
        return [slug, counter]
      end
    end

    # ⚠ テストが差し替えるためだけに 1 つに寄せてある（→ `MorningCommand#morning`）。
    def repository
      @repository ||= MessageRepository.new
      return @repository
    end

    def export_record(row, slug)
      record = {
        'slug' => slug,
        'type' => row[:type],
      }
      record['date'] = export_date(row) if row[:month]
      seasons = repository.seasons(row[:id])
      record['season'] = seasons unless seasons.empty?
      record['feature'] = row[:feature] if row[:feature]
      record['body'] = row[:body]
      return record
    end

    # ⚠ **`MM-DD`（毎年）と `YYYY-MM-DD`（その年だけ）**（→ `ScriptImporter.parse_date`）。
    def export_date(row)
      return '%{year}%<month>02d-%<day>02d' % {year: row[:year] ? "#{row[:year]}-" : '',
        month: row[:month],
        day: row[:day]}
    end

    def exclude_ids(value)
      return [] if value.blank?
      return value.split(',').map {|id| Integer(id.strip)}
    rescue ArgumentError
      raise Ginseng::ValidateError, "除く id は数字で指定してください（'#{value}'）"
    end

    # ⚠ **どこから出したファイルかを書き残す。**⚠⚠ **取り込み元が分からない原稿は、
    # 直してよいのか捨ててよいのかも分からない。**
    def export_header(records)
      types = records.map {|record| record['type']}.tally.map {|type, size| "#{type} #{size}"}
      return <<~HEADER
        # #{Package.full_name} の `makoto message export` が書き出したもの。
        # 内訳: #{types.join(' / ')}
        #
        # ⚠ 取り込みは `makoto message import`（`slug` が upsert の鍵）。
        # ⚠⚠ 消すときは行を消して `--prune` を付ける。消えるのは、このファイルに
        #   出てくる type の、slug を持つ行だけ。
        # 🔴 したがって、この type の原稿を別のファイルにも分けて置かないこと
        #   （片方を --prune で取り込むと、もう片方が消える）。
      HEADER
    end

    # ⚠ **書き込む前に見る口。**`--prune` は行を消すので、本番でいきなり流させない。
    def preview_import(importer, path)
      entries = importer.read(path)
      slugs = entries.map {|entry| entry[:slug]}
      known = MessageRepository.new.by_slug(slugs).select_map(:slug)
      puts "追加 #{slugs.size - known.size} / 更新 #{known.size}"
      return unless options[:prune]
      doomed = MessageRepository.new.by_slug.exclude(slug: slugs).order(:slug).select_map(:slug)
      puts "削除 #{doomed.size}"
      doomed.each {|slug| puts "削除: #{slug}"}
    end

    # 'MM-DD'（毎年）と 'YYYY-MM-DD'（その年だけ）の両方を受ける。
    # ⚠ **規則の正本は `ScriptImporter`**（取り込みと CLI で 2 つに割らない）。
    def parse_date(value)
      return ScriptImporter.parse_date(value.presence)
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
    # ⚠⚠ **規則の正本は `ScriptImporter.parse_date`**（#96。`LiveCommand` と同じ穴が
    # 2 箇所あった）。⚠ **空なら nil**（`MessageSelector` 側が今日に倒す）。
    def preview_date(value)
      return ScriptImporter.parse_preview_date(value)
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
