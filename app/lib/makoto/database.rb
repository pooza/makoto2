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

      def connect(dsn)
        db = Sequel.connect(dsn)
        # 外部キーは SQLite では既定で無効。有効にしないと
        # `quote.form_id` の取り違えが黙って通る。
        db.run('PRAGMA foreign_keys = ON')
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
