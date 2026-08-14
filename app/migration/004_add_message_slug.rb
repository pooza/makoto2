Sequel.migration do
  # 取り込みの鍵（#50）。⚠ **原稿は `message` テーブルの行で、DB は git 管理下に無い**
  # ので、`bydo` に入れた原稿は本番へ運ばれない。ファイルから取り込む口を作るにあたって、
  # **同じ原稿を 2 回流しても増えない**ための安定した名前が要る。
  #
  # ⚠⚠ **id は鍵にできない。**旧 DB の id をそのまま主キーにしており、
  # `makoto message add` で足した行は採番の続きを取る。取り込み元に id を持たせると
  # **CLI で足した行と衝突しうる**。⚠ `type` ＋ 日付も鍵にならない
  # （**同じ日に複数の原稿があって乱択する**のが仕様）。
  #
  # ⚠ **NULL は「ファイル由来ではない」。**旧ダンプ 388 件と `makoto message add` で
  # 足した行はすべて NULL のままで、⚠⚠ **取り込みはそれらを絶対に消さない**。
  change do
    alter_table(:message) do
      add_column :slug, String
      add_index :slug, unique: true
    end
  end
end
