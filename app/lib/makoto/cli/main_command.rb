module Makoto
  class MainCommand < Thor
    include Package

    def self.exit_on_failure?
      return true
    end

    desc 'version', 'バージョンと実行環境を表示'
    def version
      puts Package.full_name
      puts "environment: #{Environment.type}"
      puts "ruby: #{RUBY_VERSION} (YJIT: #{Environment.jit? ? 'ready' : 'no'})"
      puts "database: #{Environment.db}"
    end

    desc 'config', '設定を表示（秘密情報はマスクする）'
    def config
      puts Config.instance.secure_dump.to_yaml
    end

    desc 'status', '常駐プロセスの生死を表示'
    def status
      daemon = MakotoDaemon.new
      if daemon.alive?
        puts "running (PID #{daemon.pid})"
      else
        puts 'not running'
        exit 1
      end
    end
  end
end
