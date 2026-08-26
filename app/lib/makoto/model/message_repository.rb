module Makoto
  # 前もって用意した原稿を引く口。
  #
  # 原稿の選択は「**特定日 → 記念日 → 季節 → 無指定**」の順で、具体的なものが勝つ
  # （→ `MessageSelector`）。ここはその各段を引く材料だけを出す。
  #
  # ⚠ **`type` は配列でも渡せる。**朝挨拶は `holiday` の原稿でも上書きされるので、
  # 引く側は「使ってよい type」をまとめて指定する（→ #12）。
  class MessageRepository
    # 🔴 **落とすと決めた `type`**（#60）。⚠ いまは `birthday` の 1 つだけで、
    # **用途をライブの台本が吸収した**（→ docs/makoto-legacy.md）。
    #
    # ⚠⚠ **書ける口を塞いでおくこと。**`CorpusImporter` は**投入のたびにこの type の
    # 行を消す**ので、⚠ **足せてしまうと「足したのに次の投入で黙って消える」**という
    # 形になる（Codex の指摘・PR #207）。**消す側と足せない側を同じ定数で揃える。**
    DROPPED_TYPES = ['birthday'].freeze

    def initialize(db = Database.connection)
      @db = db
    end

    def dataset
      return @db[:message]
    end

    # ⚠ **取り込みが「全部入るか、1 件も入らないか」にするための口**（#50）。
    # ⚠⚠ **`Database.connection` を呼ばせない** — テストが差し替えた DB ではなく
    # 開発用の `tmp/db/makoto.db` を掴んでしまう。
    def transaction(&)
      return @db.transaction(&)
    end

    def by_type(type)
      return filter_type(dataset, type)
    end

    # 特定日の原稿。⚠ **`year` を省略すると「毎年効く原稿」**（`year` が NULL）。
    # 旧データ 388 件はすべて NULL なので、年を指定すると 1 件も当たらない。
    def on_date(month, day, type: nil, year: nil)
      records = dataset.where(month: month, day: day, year: year)
      return filter_type(records, type)
    end

    # 季節の原稿。`message_season` は `{"season": [6,7,8]}` を月ごとに
    # 展開した表なので、json を解かずにただの join で引ける。
    def in_season(month, type: nil)
      records = dataset
        .join(:message_season, message_id: :id)
        .where(Sequel[:message_season][:month] => month)
        .select_all(:message)
      return filter_type(records, type, qualify: true)
    end

    # 日付も季節も持たない原稿。通年で回してよいもの。
    def undated(type: nil)
      dated = @db[:message_season].select(:message_id)
      records = dataset.where(month: nil, day: nil, year: nil).exclude(id: dated)
      return filter_type(records, type)
    end

    # 原稿を足す。⚠ **原稿の追加がコード変更なしでできること**が #12 の完了条件なので、
    # 入口はここと CLI（`makoto message add`）。
    #
    # ⚠ 旧 DB の id をそのまま主キーに使っているが、**新しい行は採番が続きから
    # 始まるので投入とぶつからない**（取り込みは取り込み元の id で上書きする）。
    def create(type:, body:, **options)
      validate_type!(type)
      return @db.transaction do
        id = dataset.insert(
          type: type.to_s,
          body: body,
          month: options[:month],
          day: options[:day],
          year: options[:year],
          feature: options[:feature],
        )
        Array(options[:seasons]).each do |value|
          @db[:message_season].insert(message_id: id, month: value.to_i)
        end
        next id
      end
    end

    # `slug` を鍵に足すか差し替える（#50）。⚠ **同じ取り込みを 2 回流しても増えない。**
    #
    # ⚠⚠ **旧実装のように毎回クリアして入れ直さない。**変わっていない行はそのまま
    # 残るので、id が安定し、⚠ **`makoto message list` の並びも取り込みのたびに
    # 変わらない**。
    #
    # @return [Symbol] `:created` / `:updated`
    def upsert(slug:, type:, body:, **options)
      validate_type!(type)
      return @db.transaction do
        row = dataset[slug: slug.to_s]
        values = {
          type: type.to_s,
          body: body,
          month: options[:month],
          day: options[:day],
          year: options[:year],
          feature: options[:feature],
        }
        unless row
          id = dataset.insert(values.merge(slug: slug.to_s))
          replace_seasons(id, options[:seasons])
          next :created
        end
        dataset.where(id: row[:id]).update(values)
        replace_seasons(row[:id], options[:seasons])
        next :updated
      end
    end

    # ファイル由来の原稿（`slug` を持つ行）。⚠ **取り込みが消してよい範囲はここだけ。**
    def by_slug(slugs = nil)
      records = dataset.exclude(slug: nil)
      return records if slugs.nil?
      return records.where(slug: Array(slugs).map(&:to_s))
    end

    # 取り込み元から消えた原稿を落とす（#50 の `--prune`）。
    #
    # ⚠⚠ **`slug` を持たない行には絶対に触らない。**旧ダンプ 388 件と
    # `makoto message add` で足した原稿がそこに居る。
    #
    # @param keep [Array<String>] 残す slug
    # @return [Array<String>] 消した slug
    def prune(keep)
      records = by_slug.exclude(slug: Array(keep).map(&:to_s))
      slugs = records.order(:slug).select_map(:slug)
      dataset.where(slug: slugs).delete if slugs.any?
      return slugs
    end

    # 原稿を消す。⚠ **書き間違えた台本を SQL で直させないための口**（→ CLI の
    # `makoto message remove`）。季節の行は外部キーの `on_delete: :cascade` で落ちる。
    #
    # ⚠⚠ **投入で入った旧データも消せてしまう。**取り込み元（`var/corpus/`）に
    # 残っているので `corpus import` で戻せるが、⚠ **スナップショットは 2026-02-13 で
    # 止まっている**（人手のメタ情報は再取得できない）。
    def delete(id)
      return dataset.where(id: id).delete
    end

    # その原稿の季節指定（月の配列）。⚠ 表示に使う。引くときは `in_season`。
    def seasons(id)
      return @db[:message_season].where(message_id: id).order(:month).select_map(:month)
    end

    def count
      return dataset.count
    end

    # type => 件数。`makoto corpus stat` が使う。
    def count_by_type
      return dataset.group_and_count(:type).to_hash(:type, :count)
    end

    private

    # ⚠ **落とした type では書かせない**（#60・上記 `DROPPED_TYPES`）。
    def validate_type!(type)
      return unless DROPPED_TYPES.include?(type.to_s)
      raise Ginseng::ValidateError, "message: type '#{type}' は使わない（#60 で落とした）"
    end

    # ⚠ 差し替えなので一度消してから入れ直す。**季節は原稿に従属する情報**で、
    # 単独では意味を持たないため、行ごとの差分を取る意味が無い。
    def replace_seasons(id, seasons)
      @db[:message_season].where(message_id: id).delete
      Array(seasons).each do |value|
        @db[:message_season].insert(message_id: id, month: value.to_i)
      end
      return nil
    end

    # ⚠ 単数でも配列でも受ける。`nil` は絞り込まない。
    def filter_type(records, type, qualify: false)
      return records if type.nil?
      types = Array(type).map(&:to_s)
      return records.where(Sequel[:message][:type] => types) if qualify
      return records.where(type: types)
    end
  end
end
