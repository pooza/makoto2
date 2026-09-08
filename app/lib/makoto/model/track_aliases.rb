module Makoto
  # 同じ曲だが表記が違うものの表（#123）。
  #
  # ⚠⚠ **訂正表（`TrackImporter::CORRECTIONS`）とは別物。**🔴 **あちらは「片方が
  # 間違っている」ので曲名そのものを直す**（表示も変わる）。⚠ **こちらは「どちらも
  # 正しい」ので、鍵だけを揃える** — **投稿に出る曲名は 1 文字も変えない。**
  #
  # ## 🔴 なぜ規則で解けないか
  #
  # ⚠ **読み仮名を持っていない。**⚠⚠ **かな化しても「五匹」が `ごひき` か `ごきひ` かは
  # 辞書が要る**し、**同音別曲を潰す危険**が出る（サントラのキュー名に同名別曲が多い）。
  # 🔴 **だから規則ではなく、気づいたものを 1 件ずつ書く表にする。**
  #
  # ⚠ **`TrackName` の「`dedupe_key` の側は触らない」の唯一の例外がここ。**
  # ⚠⚠ **あちらが禁じているのは「規則を足して全 4,305 曲の鍵を動かす」こと**で、
  # 🔴 **数え上げた 2 組だけを名指しで寄せるのは、その危険を持たない。**
  #
  # ## ⚠ 突き合わせは正規化した後
  #
  # 🔴 **表に書くのは素の曲名だが、比べるのは `TrackImporter.normalize` を通した後。**
  # ⚠⚠ **半角/全角や `♪` の有無はここに書かなくてよい**（`NOISE` が先に吸収する）。
  class TrackAliases
    include Package

    FILE = 'track_aliases.yaml'.freeze

    def initialize(dir = nil)
      @dir = dir || File.join(Environment.dir, config['/track/dir'])
    end

    def path
      return File.join(@dir, FILE)
    end

    # ⚠ **表は無くてもよい**（あとから足せる）。
    def groups
      @groups ||= load_groups
      return @groups
    end

    # 別名の鍵 => 代表の鍵。⚠ **代表そのものは入れない**（自分を自分に写しても意味が無い）。
    def table
      @table ||= groups.each_with_object({}) do |names, table|
        keys = names.map {|name| TrackImporter.normalize(name)}
        keys.drop(1).each {|key| table[key] = keys.first}
      end
      return @table
    end

    # ⚠ **別名でなければ nil**（呼ぶ側は元の鍵を使う）。
    def key_for(key)
      return table[key]
    end

    # 表に出てくる鍵を全部（🔴 **代表も含む** — **「1 行も当たらない」を数えるため**）。
    def keys
      return groups.flat_map {|names| names.map {|name| TrackImporter.normalize(name)}}
    end

    def empty?
      return groups.empty?
    end

    private

    def load_groups
      return [] unless File.exist?(path)
      entries = Array(YAML.safe_load_file(path, permitted_classes: [Date], symbolize_names: true))
      return entries.map {|entry| validate(entry)}
    rescue Psych::Exception => e
      raise Ginseng::ValidateError, "#{FILE}: YAML を読めません: #{error_message(e)}"
    end

    # ⚠ **壊れた表で黙って素通ししない。**🔴 **`names` が 1 つだけの行は何もしない**
    # ので、⚠⚠ **書いたのに効いていないことに気づけない形になる。**
    def validate(entry)
      names = Array(entry[:names]).map(&:to_s).reject(&:blank?)
      raise Ginseng::ValidateError, "#{FILE}: names は 2 つ以上必要です（#{names.join(', ')}）" if
        names.size < 2
      return names
    end
  end
end
