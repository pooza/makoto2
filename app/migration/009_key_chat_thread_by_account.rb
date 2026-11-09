Sequel.migration do
  # 打ち切った会話の鍵を「根」から「根と相手の組」にする（v1.0.0 のリリース前レビューの赤）。
  #
  # 🔴 根はたいてい MAKOTO の定時投稿なので、根だけを鍵にすると、1 人が舞台裏を訊いただけで
  # 同じ投稿に返信した全員への返事が止まる。⚠ 打ち切るのは、印を付けた相手との会話だけ。
  #
  # ⚠ SQLite は主キーを付け替えられないので、作り直して写す。
  up do
    create_table(:chat_thread_new) do
      String :root_id, null: false
      String :account_id, null: false
      String :reason, null: false
      DateTime :closed_at, null: false
      primary_key [:root_id, :account_id]
    end
    self[:chat_thread_new].import(
      [:root_id, :account_id, :reason, :closed_at],
      self[:chat_thread].select(:root_id, :account_id, :reason, :closed_at),
    )
    drop_table(:chat_thread)
    rename_table(:chat_thread_new, :chat_thread)
  end

  # ⚠ 戻すときは、根ごとに最初に閉じた 1 行だけを残す。
  down do
    create_table(:chat_thread_old) do
      String :root_id, primary_key: true
      String :account_id, null: false
      String :reason, null: false
      DateTime :closed_at, null: false
    end
    self[:chat_thread].order(:closed_at).each do |row|
      next unless self[:chat_thread_old].where(root_id: row[:root_id]).empty?
      self[:chat_thread_old].insert(row)
    end
    drop_table(:chat_thread)
    rename_table(:chat_thread_old, :chat_thread)
  end
end
