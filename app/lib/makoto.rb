require 'bundler/setup'

module Makoto
  def self.dir
    return File.expand_path('../..', __dir__)
  end

  def self.loader
    config = YAML.load_file(File.join(dir, 'config/autoload.yaml'))
    loader = Zeitwerk::Loader.new
    loader.inflector.inflect(config['inflections'])
    loader.push_dir(File.join(dir, 'app/lib'))
    loader.collapse('app/lib/makoto/*')
    return loader
  end

  # 🔴 **例外の集約**（#28）。⚠ **DSN が無ければ何もしない**（開発機・CI・テスト）。
  #
  # ⚠⚠ **マスクは `Sentry.init` の外で用意する** — 🔴 **ここで落ちれば Sentry ごと立ち上がらない
  # （fail closed）**。⚠ **マスクが無いまま送る状態には決してしない。**
  # ⚠ **初期化そのものの失敗では起動を止めない**（観測のために投稿を止めない）。
  def self.setup_sentry
    dsn = sentry_dsn
    return unless dsn
    scrubber = SentryScrubber.new
    Sentry.init do |sentry|
      sentry.dsn = dsn
      sentry.release = Package.version
      sentry.environment = Environment.type
      sentry.traces_sample_rate = sentry_traces_sample_rate
      # ⚠ `send_default_pii` は既定 false のまま。
      sentry.before_send = proc {|event, _hint| scrubber.scrub(event)}
    end
  rescue => e
    # ⚠⚠ **メッセージは出さない**（Codex の P2）。🔴 **DSN が壊れていると、解析の例外メッセージに
    # DSN そのものが載りうる**（`mask_fields` に入れた値を stderr へ素で書くことになる）。
    warn "Sentry initialization skipped: #{e.class}"
  end

  # ⚠ **無ければ 0**（Codex の P2）。⚠⚠ **素で読むと、DSN だけ置いたホストで例外になり、
  # 上の rescue に落ちて Sentry が黙って立ち上がらない。**
  def self.sentry_traces_sample_rate
    return Config.instance['/sentry/traces_sample_rate'].to_f
  rescue Ginseng::ConfigError
    return 0
  end

  # ⚠⚠ **`dsn: null` は `Config#[]` では「キーが無い」になり、例外が上がる。**🔴 **素で読むと、
  # DSN を置いていない開発機・CI・テストで、すべての起動が下の rescue に落ちて警告を出す。**
  # ⚠ **空は正常な状態**なので、ここで nil に畳む。
  def self.sentry_dsn
    return Config.instance['/sentry/dsn'].presence
  rescue Ginseng::ConfigError
    return nil
  end

  def self.load_tasks
    finder = Ginseng::FileFinder.new
    finder.dir = File.join(dir, 'app/task')
    finder.patterns.push('*.rb')
    finder.patterns.push('*.rake')
    finder.exec.each {|f| require f}
  end

  Dir.chdir(dir)
  ENV['BUNDLE_GEMFILE'] = File.join(dir, 'Gemfile')
  Bundler.require
  loader.setup
  RubyVM::YJIT.enable if Environment.jit?
  # ⚠⚠ **すべての入り口がここを通る**ので、常駐も CLI も同じ時刻を見る（#110）。
  # ⚠ **要求されていなければ何もしない。**🔴 **通せない条件なら例外で落とす** —
  # 偽の日付のまま本物のインスタンスへ投稿するくらいなら起動しないほうがまし。
  TimeTravel.activate!
  setup_sentry
end
