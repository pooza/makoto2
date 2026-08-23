require 'sequel'

module Makoto
  # SQLite への接続口。
  #
  # 常駐プロセス 1 本という構成なので、接続はプロセスに 1 つで足りる。
  # ⚠ **テストは `connect` で別の接続（`sqlite:/` ＝ メモリ）を作って渡す。**
  # 既定の接続を掴むと、テストが開発用の DB を書き換える。
  class Database
    MIGRATION_DIR = 'app/migration'.freeze

    class << self
      def connection
        @connection ||= connect(Environment.dsn)
        return @connection
      end

      # 🔴 **PRAGMA はここに置く**（#80 の緑 5）。⚠⚠ **常駐が別に `Sequel.connect` して
      # PRAGMA を当てていたが、その接続は誰も使っていなかった** — **投稿の経路が使うのは
      # `connection` のほう**なので、⚠ **WAL も busy_timeout も効いていなかった。**
      # ⚠⚠ **この先ここに増やす PRAGMA も同じように空振りする形だった。**
      def connect(dsn)
        db = Sequel.connect(dsn)
        # ⚠ **SQLite 本体の既定は OFF だが、Sequel の SQLite アダプタが既定で ON にする**
        # （5.106 で確認）。つまりこの 1 行が無くても外部キーは効く。**上流の既定に
        # 依存しないための明示**であって、消しても今すぐ壊れるわけではない。
        db.run('PRAGMA foreign_keys = ON')
        # ⚠ 読み手（`makoto status` / 下見）と常駐の書き込みが噛み合わないようにする。
        db.run('PRAGMA journal_mode = WAL')
        # ⚠ 書き込みが競ったときに即座に諦めない（既定は 0 ＝ すぐ `SQLITE_BUSY`）。
        db.run('PRAGMA busy_timeout = 5000')
        return db
      end

      # マイグレーションを当てる。`rake migration:run` と、テストの
      # メモリ DB の両方から使う（同じ経路を通しておかないと、テストが
      # 通るスキーマと本番のスキーマがずれる）。
      def migrate(db = connection)
        Sequel.extension(:migration)
        Sequel::Migrator.run(db, File.join(Environment.dir, MIGRATION_DIR))
        return db
      end
    end
  end
end
