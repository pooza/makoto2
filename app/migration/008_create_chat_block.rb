Sequel.migration do
  # チャットボットが返事をしない相手（#20）。🔴 **人の手でだけ増える**（`makoto chat block`）。
  #
  # 🔴 **載った相手には、次のメンションに決まった文を 1 回だけ返し、あとは黙る**（2026-11-09・オーナー）。
  # ⚠ 黙る理由を本人に一度は伝える（表示しないまま実質ブロックするのは不誠実）。周りからは静か。
  #
  # ⚠ **鍵は Mastodon のアカウント ID**（acct は変えられる・006 と同じ）。⚠ 本文は持たない。
  change do
    create_table(:chat_block) do
      String :account_id, primary_key: true
      String :acct, null: false
      DateTime :blocked_at, null: false
      String :note
    end
  end
end
