module Makoto
  class Environment < Ginseng::Environment
    include Package

    def self.name
      return File.basename(dir)
    end

    def self.dir
      return Makoto.dir
    end

    def self.type
      return config['/environment'] || 'development'
    end

    def self.development?
      return type == 'development'
    end

    def self.production?
      return type == 'production'
    end

    def self.rake?
      return ENV['RAKE'].present? && !test? rescue false
    end

    def self.test?
      return ENV['TEST'].present? rescue false
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
