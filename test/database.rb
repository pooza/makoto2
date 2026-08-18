module Makoto
  # 🔴 **PRAGMA が実際に効いていること**（#80 の緑 5）。
  #
  # ⚠⚠ **常駐が別に `Sequel.connect` して PRAGMA を当てていたが、その接続は誰も
  # 使っていなかった。**⚠ **投稿の経路が使うのは `Database.connection` のほう**なので、
  # **WAL も busy_timeout も効いていなかった。**
  #
  # ⚠ **「設定してあるつもり」は当てにしない。**⚠⚠ **当てた先を読み返して確かめる。**
  class DatabaseTest < TestCase
    def path
      return File.join(Environment.dir, 'tmp/db/pragma_test.db')
    end

    setup do
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.rm_f(path)
    end

    teardown do
      @db&.disconnect
      FileUtils.rm_f(path)
    end

    def db
      @db ||= Database.connect("sqlite://#{path}")
      return @db
    end

    # ⚠ 読み手（`makoto status` / 下見）と常駐の書き込みが噛み合わないようにする。
    def test_journal_mode_is_wal
      assert_equal('wal', db.fetch('PRAGMA journal_mode').first[:journal_mode].to_s.downcase)
    end

    # ⚠ 既定は 0（＝ すぐ `SQLITE_BUSY`）。競ったときに即座に諦めない。
    def test_busy_timeout_is_set
      assert_equal(5000, db.fetch('PRAGMA busy_timeout').first[:timeout])
    end

    def test_foreign_keys_are_on
      assert_equal(1, db.fetch('PRAGMA foreign_keys').first[:foreign_keys])
    end

    # 🔴 **常駐が掴む接続が、投稿の経路の使うものと同じであること。**
    # ⚠⚠ **別の接続を作っていたのが緑 5 の中身。**
    def test_the_daemon_uses_the_shared_connection
      assert_same(Database.connection, MakotoDaemon.new.send(:connect_db))
    end
  end
end
