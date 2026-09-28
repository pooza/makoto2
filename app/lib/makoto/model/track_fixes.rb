module Makoto
  # 曲名の訂正表（#58 → `TrackImporter::CORRECTIONS`）と、`kind` の分類を正す表（#304 →
  # `TrackImporter::KINDS`）の読み込みと検査。
  #
  # ⚠ **`TrackImporter` から分けた**（#317）。🔴 **表の形の検査を足したら、クラスの長さの上限を超えた。**
  # ⚠ **当て方（`from` が一致したときだけ正す）は `TrackImporter` のまま**（取り込みの最中に警告を出すため）。
  class TrackFixes
    include Package

    def initialize(dir)
      @dir = dir
    end

    # ⚠ 訂正表は無くてもよい（あとから足せる）。
    #
    # @return [Hash{Integer => Hash}] `trackId` ごとの行
    def corrections
      @corrections ||= load_corrections.to_h {|entry| [entry[:id], entry]}
      return @corrections
    end

    # ⚠ 分類の表は無くてもよい（あとから足せる）。
    #
    # @return [Hash{Integer => Hash}] `trackId` ごとの行
    def kinds
      @kinds ||= load_kinds.to_h {|entry| [entry[:id], entry]}
      return @kinds
    end

    private

    def path(file)
      return File.join(@dir, file)
    end

    def load_corrections
      file = TrackImporter::CORRECTIONS
      return [] unless File.exist?(path(file))
      # ⚠⚠ **`safe_load` を使う**（`noticed: 2026-08-14` は Psych が `Date` にする）。
      entries = Array(YAML.safe_load_file(path(file),
        permitted_classes: [Date], symbolize_names: true))
      return entries.map {|entry| validate_entry(file, entry)}
    rescue Psych::Exception => e
      raise Ginseng::ValidateError, "#{file}: YAML を読めません: #{error_message(e)}"
    end

    def load_kinds
      file = TrackImporter::KINDS
      return [] unless File.exist?(path(file))
      entries = Array(YAML.safe_load_file(path(file),
        permitted_classes: [Date], symbolize_names: true))
      return entries.map {|entry| validate_kind(entry)}
    rescue Psych::Exception => e
      raise Ginseng::ValidateError, "#{file}: YAML を読めません: #{error_message(e)}"
    end

    # 🔴 **訂正表と分類の表の行の形**（#317）。⚠⚠ **`id` は数値**（`trackId`）— **引用符で囲むと文字列に
    # なり、どの曲にも当たらないまま気づけなかった。**⚠ **`from` / `to` は空にしない。**
    def validate_entry(file, entry)
      raise Ginseng::ValidateError, "#{file}: 行が Hash ではありません（#{entry.inspect}）" unless
        entry.is_a?(Hash)
      unless entry[:id].is_a?(Integer)
        raise Ginseng::ValidateError, "#{file}: id は数値で書きます（引用符で囲まない・#{entry[:id].inspect}）"
      end
      [:from, :to].each do |key|
        next if entry[key].to_s.present?
        raise Ginseng::ValidateError, "#{file}: id #{entry[:id]} の #{key} が空です"
      end
      return entry
    end

    # 🔴 **`to` は抽選の重みがある `kind` だけ。**⚠⚠ **重みの無い `kind` に正すと、
    # その曲は抽選で永久に出ない**（`TrackLottery` は警告を出すだけ）。
    def validate_kind(entry)
      file = TrackImporter::KINDS
      entry = validate_entry(file, entry)
      entry = entry.merge(from: entry[:from].to_s, to: entry[:to].to_s)
      return entry if config.keys(TrackLottery::WEIGHT_PREFIX).map(&:to_s).include?(entry[:to])
      raise Ginseng::ValidateError,
        "#{file}: id #{entry[:id]} の to '#{entry[:to]}' は" \
          " #{TrackLottery::WEIGHT_PREFIX} に無い kind です"
    end
  end
end
