module Makoto
  module Package
    def environment_class
      return Environment
    end

    def package_class
      return Package
    end

    def config_class
      return Config
    end

    def config
      return Config.instance
    end

    def logger_class
      return Logger
    end

    def logger
      @logger ||= Logger.new
      return @logger
    end

    def http_class
      return HTTP
    end

    # 例外のメッセージを UTF-8 として安全に埋め込める形にする。
    #
    # ⚠ **Sequel / SQLite の例外メッセージは ASCII-8BIT で上がってくる。**台詞のような
    # 非 ASCII が SQL に含まれると、`"...: #{e.message}"` と書いた瞬間に
    # `Encoding::CompatibilityError` になる。**エラー処理そのものが落ちるので、
    # 本当のエラーが見えなくなる**（無人で動くボットでは、これが一番たちが悪い）。
    def error_message(error)
      return error.message.dup.force_encoding(Encoding::UTF_8).scrub
    end

    def self.name
      return 'makoto2'
    end

    def self.version
      return Config.instance['/package/version']
    end

    def self.url
      return Config.instance['/package/url']
    end

    def self.full_name
      return "#{name} #{version}"
    end

    def self.user_agent
      return "#{name}/#{version} (#{url})"
    end

    def self.included(base)
      base.extend(Methods)
    end

    module Methods
      def logger
        return Logger.new
      end

      def config
        return Config.instance
      end
    end
  end
end
