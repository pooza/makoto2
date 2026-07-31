module Makoto
  # 前もって用意した原稿を引く口。
  #
  # 旧実装の原稿選択は「**特定日（month/day）→ 季節（season）→ 無指定**」の
  # 3 段構えだった。ここはその各段を引く材料だけを出し、どう落とすかは
  # 原稿の上書き機構（#12）側で決める。
  class MessageRepository
    def initialize(db = Database.connection)
      @db = db
    end

    def dataset
      return @db[:message]
    end

    def by_type(type)
      return dataset.where(type: type.to_s)
    end

    # 特定日の原稿。旧データで日付を持つのは holiday の 6 件だけ。
    def on_date(month, day, type: nil)
      records = dataset.where(month: month, day: day)
      records = records.where(type: type.to_s) if type
      return records
    end

    # 季節の原稿。`message_season` は `{"season": [6,7,8]}` を月ごとに
    # 展開した表なので、json を解かずにただの join で引ける。
    def in_season(month, type: nil)
      records = dataset
        .join(:message_season, message_id: :id)
        .where(Sequel[:message_season][:month] => month)
        .select_all(:message)
      records = records.where(Sequel[:message][:type] => type.to_s) if type
      return records
    end

    # 日付も季節も持たない原稿。通年で回してよいもの。
    def undated(type: nil)
      dated = @db[:message_season].select(:message_id)
      records = dataset.where(month: nil, day: nil).exclude(id: dated)
      records = records.where(type: type.to_s) if type
      return records
    end

    def count
      return dataset.count
    end

    # type => 件数。`makoto corpus stat` が使う。
    def count_by_type
      return dataset.group_and_count(:type).to_hash(:type, :count)
    end
  end
end
