module Makoto
  # ファイルに書いた原稿を `message` へ取り込む（#50）。
  #
  # ⚠⚠ **原稿は `message` テーブルの行で、DB は git 管理下に無い。**したがって
  # `bydo` に入れた原稿は本番へ運ばれない。曲データ（`seed/`）は git 管理下なので
  # `track import` だけで入るが、⚠ **原稿にはその経路が無かった。**
  #
  # ⚠ **ライブの台本（#13）で効く。**8 時間ぶんの原稿を本番で手打ちすることになり、
  # **当日の台本を打ち間違える**という一番痛い壊れ方につながる。
  #
  # ## 形式
  #
  # ```yaml
  # - slug: live-eve-01     # ⚠ 取り込みの鍵。必須
  #   type: live_eve
  #   date: 2026-11-03      # YYYY-MM-DD（その年だけ）/ MM-DD（毎年）/ 省略
  #   body: |-
  #     明日はわたしの誕生日。
  # ```
  #
  # ⚠⚠ **旧実装のように毎回クリアして入れ直さない。**`slug` で upsert するので、
  # **変わっていない行はそのまま残る**（id が動かず、`makoto message list` の並びも
  # 取り込みのたびに変わらない）。
  #
  # ⚠⚠ **削除は `--prune` を明示したときだけ。**しかも **`slug` を持つ行しか消さない**
  # ので、旧ダンプ 388 件と `makoto message add` で足した原稿には触らない。
  class ScriptImporter
    include Package

    EXTENSIONS = ['.yaml', '.yml'].freeze

    Result = Struct.new(:created, :updated, :pruned, keyword_init: true) do
      def to_s
        text = "追加 #{created} / 更新 #{updated}"
        return text if pruned.nil?
        return "#{text} / 削除 #{pruned.size}"
      end
    end

    def initialize(repository: nil)
      @repository = repository || MessageRepository.new
    end

    # @param path [String] ファイルまたはディレクトリ
    # @param prune [Boolean] ⚠ 取り込み元から消えた原稿を落とすか
    # @return [Result]
    def import(path, prune: false)
      entries = read(path)
      raise Ginseng::ValidateError, "原稿が 1 件もありません（'#{path}'）" if entries.empty?
      created = 0
      updated = 0
      pruned = nil
      @repository.transaction do
        entries.each do |entry|
          case @repository.upsert(**entry)
          when :created then created += 1
          else updated += 1
          end
        end
        pruned = @repository.prune(entries.map {|entry| entry[:slug]}) if prune
      end
      return Result.new(created: created, updated: updated, pruned: pruned)
    end

    # 取り込まずに読むだけ。⚠ **下見と、形式の検査に使う。**
    def read(path)
      entries = files(path).flat_map {|file| parse(file)}
      duplicated = entries.map {|entry| entry[:slug]}.tally.select {|_, count| count > 1}.keys
      if duplicated.any?
        raise Ginseng::ValidateError, "slug が重複しています: #{duplicated.sort.join(', ')}"
      end
      return entries
    end

    private

    def files(path)
      return [path] if File.file?(path)
      raise Ginseng::ValidateError, "'#{path}' がありません" unless File.directory?(path)
      # ⚠ 名前順に読む。**読む順で id の採番が変わる**ので、実行のたびに揺れないこと。
      return Dir.glob(File.join(path, '*')).select do |file|
        EXTENSIONS.include?(File.extname(file))
      end.sort
    end

    def parse(file)
      records = load_yaml(file)
      unless records.is_a?(Array)
        raise Ginseng::ValidateError, "#{File.basename(file)}: 原稿の配列を書いてください"
      end
      return records.map.with_index {|record, index| entry(record, file, index)}
    end

    # ⚠ **`date: 2026-11-03` は Psych が `Date` にする**ので許可する。
    # ⚠⚠ **`safe_load` を使う**（原稿のファイルに Ruby のオブジェクトを書かせない）。
    def load_yaml(file)
      return YAML.safe_load_file(file, permitted_classes: [Date])
    rescue Psych::Exception => e
      # ⚠ `SyntaxError`（壊れている）と `DisallowedClass`（`!ruby/object` などの
      # 使えない書き方）の両方をここで受ける。**どちらも「読めない」で止める。**
      raise Ginseng::ValidateError, "#{File.basename(file)}: YAML を読めません: #{error_message(e)}"
    end

    def entry(record, file, index)
      where = "#{File.basename(file)} の #{index + 1} 件目"
      unless record.is_a?(Hash)
        raise Ginseng::ValidateError, "#{where}: slug / type / body を持つ表を書いてください"
      end
      slug = record['slug'].to_s.strip
      raise Ginseng::ValidateError, "#{where}: slug がありません" if slug.empty?
      type = record['type'].to_s.strip
      raise Ginseng::ValidateError, "#{slug}: type がありません" if type.empty?
      body = record['body'].to_s
      raise Ginseng::ValidateError, "#{slug}: body がありません" if body.strip.empty?
      return {
        slug: slug,
        type: type,
        body: body,
        feature: record['feature'],
        seasons: seasons(record['season'], slug),
        **self.class.parse_date(record['date'], slug),
      }
    end

    def seasons(value, slug)
      months = Array(value).map {|month| month.to_s.strip.to_i}
      return months if months.all? {|month| month.between?(1, 12)}
      raise Ginseng::ValidateError, "#{slug}: 季節は 1〜12 の月で指定してください"
    end

    class << self
      # 'MM-DD'（毎年）と 'YYYY-MM-DD'（その年だけ）の両方を受ける。
      # ⚠ **CLI（`makoto message add --date`）と同じ規則**。2 つに割らないためここに置く。
      def parse_date(value, label = nil)
        return {year: nil, month: nil, day: nil} if value.nil?
        return {year: value.year, month: value.month, day: value.day} if value.is_a?(Date)
        text = value.to_s.strip
        return {year: nil, month: nil, day: nil} if text.empty?
        if (matches = text.match(/\A(\d{4})-(\d{1,2})-(\d{1,2})\z/))
          return {year: matches[1].to_i, month: matches[2].to_i, day: matches[3].to_i}
        end
        if (matches = text.match(/\A(\d{1,2})-(\d{1,2})\z/))
          return {year: nil, month: matches[1].to_i, day: matches[2].to_i}
        end
        prefix = label ? "#{label}: " : ''
        raise Ginseng::ValidateError,
          "#{prefix}日付は MM-DD か YYYY-MM-DD で指定してください（'#{value}'）"
      end
    end
  end
end
