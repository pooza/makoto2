module Makoto
  # 本編の台詞を引く口。
  #
  # ⚠ **`respondable` 以外を応答に使わない。**旧 DB の `exclude` /
  # `exclude_respond` は人手で付いた「使ってよいか」の判断で、再取得できない。
  # 生の `dataset` には投稿専用（289 件）と完全封印（106 件）が混ざっている。
  class QuoteRepository
    def initialize(db = Database.connection)
      @db = db
    end

    def dataset
      return @db[:quote]
    end

    # 応答に使ってよい台詞だけ。
    #
    # `form` は変身前後の別（`キュアソード` / `剣崎真琴` / `ちびキュアソード`）で、
    # 名前でも id でも渡せる。`series` は出典作品の id。
    def respondable(form: nil, series: nil)
      records = dataset.where(exclude: false, exclude_respond: false)
      records = records.where(form_id: form_id(form)) if form
      records = records.where(series_id: series) if series
      return records
    end

    # 抽選の重みに使う `priority`（1〜5）の高い順。同点は id 順で安定させる。
    def by_priority(records = respondable)
      return records.order(Sequel.desc(:priority), :id)
    end

    def count
      return dataset.count
    end

    def respondable_count
      return respondable.count
    end

    # 変身前後の別を name => id で返す。
    def forms
      return @db[:form].to_hash(:name, :id)
    end

    private

    # `form` は名前でも id でも受ける。
    # ⚠ 未知の名前を黙って nil にしない。nil は「絞り込まない」と区別が付かず、
    # 綴りを間違えた瞬間に**全件が応答対象になる**。
    def form_id(form)
      return form if form.is_a?(Integer)
      id = forms[form.to_s]
      raise Ginseng::NotFoundError, "unknown form '#{form}'" unless id
      return id
    end
  end
end
