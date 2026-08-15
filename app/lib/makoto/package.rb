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

    # 省略できる設定を読む。⚠ **無ければ既定値**。
    #
    # ⚠⚠ **`Config#[]` はキーが無ければ例外を上げる。**したがって「設定を消せば止まる」
    # と説明した設定を素の `config[]` で読むと、⚠ **消した瞬間に落ちる。**
    # ⚠⚠ **しかも `rake config:lint` は通る**（schema が必須にしていないため）ので、
    # **その設定を使う瞬間まで分からない**（0.2.0 のリリース前レビューで実測・#77）。
    #
    # ⚠ **落ち方が 2 通りに分かれるのが厄介** — 起動時に読むもの（`/live/hashtag`）は
    # 常駐が起動せず監視が拾えるが、⚠⚠ **枠の中で読むものは `PostingJob` の rescue に
    # 飲まれ、「登録ジョブ 5 で健全」のまま 160 枠が沈黙する。**
    #
    # ⚠⚠ **fail-open な `rescue` にしない。**⚠ **キーの有無だけを見て、値を読む側の
    # 失敗は握り潰さない**（→ docs/CLAUDE.md「fail-open な rescue の内側で設定値を
    # 読まない」）。`rescue` にすると、設定パスの typo が同じ穴に落ちる。
    def optional_config(key, default = nil)
      return default unless config.key?(key)
      return config[key]
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
