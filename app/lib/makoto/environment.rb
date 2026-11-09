module Makoto
  class Environment < Ginseng::Environment
    include Package

    def self.dir
      return Makoto.dir
    end

    # ginseng-upstream: no — 常駐は Rack で起動しないので RACK_ENV / RAILS_ENV を見ず、
    # 設定の `/environment` だけを正とする（上流は Rack のアプリに合わせて環境変数を先に見る）
    def self.type
      return config['/environment'] || 'development'
    end

    def self.rake?
      return ENV['RAKE'].present? && !test? rescue false
    end

    # ⚠ **テストは開発用の DB を掴まない。**テストは基本的にメモリ DB を作って
    # 使うが、渡し忘れた経路がここに落ちてきたときに `makoto.db` を書き換えると
    # 投入済みのコーパスが壊れる。落ちる先を分けて、事故を「テストが落ちる」で
    # 済ませる。
    def self.db
      name = test? ? 'test.db' : config['/sqlite3/db']
      return File.join(dir, 'tmp/db', name)
    end

    def self.dsn
      return "sqlite://#{db}"
    end
  end
end
