require 'bundler/setup'
require 'syslog/logger'

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
      # 🔴 **外向きの要求にトレースの文脈を足さない**（v0.6.0 のリリース前レビュー・黄）。
      # ⚠⚠ **既定の `true` は `Net::HTTP` へのパッチを通じて、すべての送信要求に
      # `Sentry-Trace` と `Baggage` を付ける** — ⚠ **`Baggage` には `sentry-public_key=<DSN の鍵>`
      # が載る**ので、**投稿 1 本ごと（ライブ当日は 160 本）と cure-api への要求に、
      # `mask_fields` へ入れたはずの鍵が平文で出ていく。**
      # ⚠⚠ **`traces_sample_rate` を 0 にしても止まらない**（標本化ではなく伝播の設定）。
      # ⚠ **MAKOTO は誰ともトレースを繋いでいない**ので、失うものは無い。
      sentry.propagate_traces = false
      # ⚠ `send_default_pii` は既定 false のまま。
      # 🔴 **フレームのローカル変数を送らない**（#347）。⚠⚠ **`PostingJob` の `rescue` の
      # 内側には `text`（投稿本文そのもの）が居る**ので、**変数が乗ると原稿・本文が
      # そのまま public な箱の外へ出る。**
      # ⚠ **既定は false だが明示する** — 🔴 **`propagate_traces` で「既定に任せていたら
      # 既定が危ない側だった」を踏んでいる**（v0.6.0 のリリース前レビュー・黄）。
      # ⚠⚠ **`send_default_pii=` を足すときはこの行より後ろに置かない** — **代入が
      # `data_collection` を丸ごと差し替える**（`sentry-ruby` 7.0.0 `configuration.rb:635`）。
      sentry.data_collection.stack_frame_variables = false
      # 🔴 **breadcrumb は 1 つも積んでいない**（`Sentry.add_breadcrumb` は 0 件・実測）。
      # ⚠⚠ **既定は 100 件**（`breadcrumb_buffer.rb:7`）で、**積まないものを運ぶ容れ物を
      # 開けておく理由が無い**（#347）。⚠ **`SentryScrubber#scrub_breadcrumbs` は残す** —
      # **この行を消された日に素通しにしない。**
      sentry.max_breadcrumbs = 0
      sentry.before_send = proc {|event, _hint| scrubber.scrub(event)}
    end
    report_sentry_unsendable unless sentry_state == :on
  rescue => e
    report_sentry_setup_error(e)
  end

  # Sentry が送れる状態か（#347）。
  #
  # | 値 | 意味 |
  # | --- | --- |
  # | `:off` | DSN が無い（開発機・CI・テスト）＝ 正常 |
  # | `:on` | 送れる |
  # | 🔴 `:misconfigured` | DSN はあるのに送れない（初期化に失敗した・DSN の形でない） |
  #
  # ⚠⚠ **`Sentry.initialized?` だけでは足りない** — 🔴 **`https://` だが DSN でない値（WebUI の
  # プロジェクトの URL など）は、初期化に成功して 1 件も送らない**（`sending_allowed?` が偽）。
  def self.sentry_state
    return :off unless sentry_dsn
    return :misconfigured unless defined?(Sentry) && Sentry.initialized?
    return :misconfigured unless Sentry.configuration.sending_allowed?
    return :on
  rescue
    return :misconfigured
  end

  # 🔴 **初期化に成功したのに送れない形を 1 行残す**（#347）。⚠⚠ **sentry-ruby 自身の警告は
  # `STDOUT` へ出る**ので、常駐では消える（→ `report_sentry_setup_error`）。⚠ **DSN は出さない。**
  def self.report_sentry_unsendable
    Logger.new.error(sentry: 'init',
      message: 'initialized but will not send (the DSN is not valid)')
  end

  # 🔴 **`warn` で出さない**（v0.6.0 のリリース前レビュー・赤）。⚠⚠ **`bin/makoto_daemon.rb` は
  # `start` / `restart` のとき `require 'makoto'` より前に `$stderr` を `/dev/null` へ繋ぐ**ので、
  # **本番ではこの 1 行が丸ごと消える** — ⚠ **`report_error` は `Sentry.initialized?` が false の
  # あいだ全経路で no-op になる**ので、**「入れたつもりで 1 件も集まらない」に誰も気付けない。**
  # 🔴 **`SentryScrubber#report_drop` と同じ倒し方**（logger → 落ちたら syslog）。
  #
  # ⚠⚠ **メッセージは出さない**（Codex の P2）。🔴 **DSN が壊れていると、解析の例外メッセージに
  # DSN そのものが載りうる**（`mask_fields` に入れた値を素で書くことになる）。
  def self.report_sentry_setup_error(error)
    Logger.new.error(sentry: 'init', message: 'initialization skipped',
      error_class: error.class.name)
  rescue => e
    report_sentry_setup_error_fallback(error, e)
  end

  # 🔴 **最後の 1 手で起動を巻き込まない**（Codex の P2）。⚠⚠ **ここは `setup_sentry` の rescue の
  # 中から呼ばれる**ので、**syslog も使えない箱でここが例外を上げると、観測のための 1 行が
  # 常駐を落とす。**⚠ **`SentryScrubber#report_drop_fallback` と同じく、諦めて nil を返す。**
  def self.report_sentry_setup_error_fallback(error, log_error)
    ::Syslog::Logger.new(Package.name).error(
      "sentry init: initialization skipped: #{error.class} (logging failed: #{log_error.class})",
    )
  rescue
    return nil
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
