Sequel.migration do
  # チャットボット（#18）が返事をしないと決めた会話（スレッド）。
  #
  # 🔴 **舞台裏を訊かれて認めたら、そのスレッドにはもう応答しない**（#510・2026-10-20 オーナー）。
  # ⚠ **打ち切るのはそのスレッドだけ** — 別の話題で話しかけてくれれば応答する。
  # ⚠ 運営を名乗った入力のスレッドも打ち切る（印でペナルティも掛かる）。
  #
  # ⚠ **鍵はスレッドの根の投稿の ID**（返信の祖先の先頭・祖先が無ければその投稿）。
  # ⚠ **本文は持たない**（006 と同じ）。
  change do
    create_table(:chat_thread) do
      String :root_id, primary_key: true
      String :account_id, null: false
      String :reason, null: false
      DateTime :closed_at, null: false
    end
  end
end
