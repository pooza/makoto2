Sequel.migration do
  change do
    # 変身前後の別（キュアソード / 剣崎真琴 / ちびキュアソード）。
    # ⚠ 口調がここで分かれている。ペルソナ切替に直結するので、台詞と一緒に移す。
    create_table(:form) do
      primary_key :id
      String :name, null: false
      index :name, unique: true
    end

    # 台詞の出典作品。
    #
    # ⚠ **ここはプリキュアの情報の正本ではない。**正本は cure-api。この表は
    # 旧 DB のダンプに入っていた出典をそのまま移したものにすぎず、`name` は
    # ダンプ由来の文字列（＝ソースコードに作品名を書いていない）。作品の情報が
    # 要るときは `cure_api_key` を使って cure-api へ引きに行く。
    #
    # `cure_api_key` が null なのは劇場版・オールスターズで、cure-api の
    # `/series` は TV シリーズしか返さないため。足りない情報は MAKOTO 側に
    # 抱え込まず cure-api を伸ばす（docs/CLAUDE.md の方針）。
    create_table(:series) do
      primary_key :id
      String :name, null: false
      String :cure_api_key
      index :name, unique: true
    end

    # 本編の台詞。旧 DB の `quote` をそのまま移す。
    #
    # ⚠ **人手で付いた `exclude` / `exclude_respond` / `priority` / `form_id` が
    # 資産の本体。**再取得できない（唯一のスナップショットが 2026-02-13 で止まって
    # いる）ので、列を減らさずに移す。
    create_table(:quote) do
      primary_key :id
      foreign_key :series_id, :series
      foreign_key :form_id, :form, null: false
      Integer :episode
      # 旧実装の好感度モデルで「怒って返す」台詞に付いていた印（`bad` 25 件）。
      # 好感度モデル自体は引き継がないが、区分は人手の情報なので残す。
      String :emotion
      # `exclude` は完全封印、`exclude_respond` は投稿には使うが応答には使わない。
      # 応答に使えるのは両方 false のものだけ（→ QuoteRepository#respondable）。
      TrueClass :exclude, null: false, default: false
      TrueClass :exclude_respond, null: false, default: false
      Integer :priority, null: false, default: 3
      String :body, null: false, text: true
      String :remark, text: true
      index [:exclude, :exclude_respond]
      index :form_id
    end

    # 前もって用意した原稿。旧 DB の `message`。
    # `type` が絞り込んだ 4 機能とほぼ一対一に対応する。
    create_table(:message) do
      primary_key :id
      String :type, null: false
      # 未実装だった「キーワード学習」の名残（`keyword` テーブルは 0 件）。
      # 4 機能では使わないが、人手で付いた情報なので落とさずに持つ。
      String :feature
      String :body, null: false, text: true
      # 特定日の指定。旧データで使っているのは holiday の 6 件だけ。
      Integer :month
      Integer :day
      index :type
      index [:month, :day]
    end

    # 原稿の季節指定。旧 DB では `message.data` に `{"season": [6,7,8]}` という
    # json が入っていた。**月ごとの行に展開する**ことで、「6 月の朝挨拶」が
    # json を解かずにただの WHERE で引ける。
    create_table(:message_season) do
      foreign_key :message_id, :message, null: false, on_delete: :cascade
      Integer :month, null: false
      primary_key [:message_id, :month]
      index :month
    end
  end
end
