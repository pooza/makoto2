Sequel.migration do
  # チャットボットのモデレーション（#510）。⚠ **応答してよいかの判定にだけ使う。**
  #
  # `chat_event`: 相手に返したもの（LLM の応答・決まった文）の記録。🔴 **回数の上限を数える。**
  # ⚠ **本文は持たない**（メンバーの書いたもの・MAKOTO が返したものとも）。
  # ⚠ 行は応答のたびに 1 行（全体の上限が 1 日 100 回なので、10 年でも 40 万行に届かない）。
  #
  # `chat_penalty`: 悪戯の印が付いた相手。🔴 **印の回数でペナルティを延ばす**（2026-11-07・オーナー）。
  # ⚠ **鍵は Mastodon のアカウント ID**（acct は変えられる）。
  change do
    create_table(:chat_event) do
      primary_key :id
      String :account_id, null: false
      String :acct, null: false
      # respond / ask_follow / limit_notice
      String :kind, null: false
      DateTime :at, null: false
      index [:account_id, :kind, :at]
      index [:kind, :at]
    end

    create_table(:chat_penalty) do
      String :account_id, primary_key: true
      String :acct, null: false
      Integer :marks, null: false, default: 0
      DateTime :until_at
      DateTime :marked_at
      String :reason
      String :status_url
    end
  end
end
