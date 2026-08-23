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
end
