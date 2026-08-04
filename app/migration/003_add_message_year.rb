Sequel.migration do
  # 原稿の「その年だけ」の指定。⚠ 旧 DB は `month` / `day` しか持たず、**毎年効く
  # 原稿しか書けなかった**。バースデーライブの台本（#13）や 11/1 からの予告（#14）は
  # **2026 年だけの原稿**なので、年で分ける手段が要る。
  #
  # ⚠ **NULL は「毎年」。**旧データ 388 件はすべて NULL のまま毎年効く。
  change do
    alter_table(:message) do
      add_column :year, Integer
      add_index [:year, :month, :day]
    end
  end
end
