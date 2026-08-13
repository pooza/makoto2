module Makoto
  # 11/4 バースデーライブ SONGBIRD PARTY 2026（#13）。**このプロジェクトのゴール**
  # （→ [birthday-live.md](../../../docs/birthday-live.md)）。
  #
  # ⚠ **枠は 4 つ。**開始告知で始まり、8 時間の進行を挟んで、終了告知で終わる。
  # 前日（11/3）の増量は**別の枠**として持つ（→ docs/CLAUDE.md「枠は 1 日 1 本。
  # 11/3 の増量でここを広げない」）。
  #
  # | 枠 | 時刻 | 中身 |
  # | --- | --- | --- |
  # | `live-eve` | 11/3 | 前日の増量。助走をつける |
  # | `live-open` | 12:00 | 開始告知。⚠⚠ **ミュート導線をここに書く**（#13 の完了条件） |
  # | `live` | 12:02〜20:00 | 曲・カバー・MC（→ `Setlist` / `LiveProgram`） |
  # | `live-close` | 20:00 | 終了告知 |
  #
  # ⚠⚠ **日付は枠ではなく原稿が持つ**（#14 と同じ形）。枠は毎日あり、その日の原稿が
  # 無ければ `MessageSelector` が nil を返して何も投稿しない。⚠ **したがって進行の枠も
  # 毎日「空回り」する**が、⚠⚠ **曲は原稿ではないので黙らせるものが無い。**
  # そのため**進行の枠だけは記念日の登録を見て、ライブ当日以外は何も返さない**
  # （→ `#live_day?`）。
  #
  # ⚠ **怒りは台本に持ち込まない**（2026-08-13 決定 / #13 の未決だった論点）。ライブは
  # 文字通りステージで、本編の真琴なら怒る場面が起きうるが、**コミュニティボットが
  # 利用者に怒るのは運用上危ない。**2024 年の台本と同じく「聴きたくない方はミュート
  # してくださいね」＝**退出路を示す**形で処理する（参加は任意 → docs/CLAUDE.md）。
  # ⚠ 敵対的な相手への対処そのものは #20。
  class Live
    include Package

    PREFIX = '/live'.freeze

    # ⚠ **冪等キーの前半になるので動かさない**（`{name}-{枠の時刻 UTC}`）。
    NAME = 'live'.freeze
    OPEN_NAME = 'live-open'.freeze
    CLOSE_NAME = 'live-close'.freeze
    EVE_NAME = 'live-eve'.freeze

    # @param repository [MessageRepository] テストが差し替えるためだけの口
    # @param tracks [TrackRepository] 同上
    def initialize(repository: nil, tracks: nil, cure_api: nil)
      @repository = repository
      @tracks = tracks
      @cure_api = cure_api
    end

    # 常駐に登録する 4 本。⚠ **登録の順は投稿の順ではない**（どれも枠の頭で判定する）。
    def jobs
      validate
      return [eve_job, open_job, program_job, close_job]
    end

    def open_job
      return PostingJob.new(name: OPEN_NAME, timetable: timetable('open'), source: selector('open'))
    end

    def close_job
      return PostingJob.new(
        name: CLOSE_NAME, timetable: timetable('close'), source: selector('close'),
      )
    end

    def eve_job
      return PostingJob.new(name: EVE_NAME, timetable: timetable('eve'), source: selector('eve'))
    end

    def program_job
      return PostingJob.new(name: NAME, timetable: timetable, source: program)
    end

    def program
      @program ||= LiveProgram.new(
        timetable: timetable,
        mc_selector: selector('mc'),
        # ⚠ ライブ当日かの判定は開始告知の記念日登録を見る（→ `LiveProgram#live_day?`）。
        gate: selector('open'),
        repository: @tracks,
        cure_api: @cure_api,
      )
      return @program
    end

    # 枠。⚠ 名前を省略すると 8 時間の進行そのもの。
    def timetable(name = nil)
      prefix = [PREFIX, name, 'timetable'].compact.join('/')
      @timetables ||= {}
      @timetables[name.to_s] ||= Timetable.new(
        start: config["#{prefix}/start"],
        finish: config["#{prefix}/finish"],
        interval: config["#{prefix}/interval"],
      )
      return @timetables[name.to_s]
    end

    def type(name)
      return config["#{PREFIX}/#{name}/type"].to_s
    end

    def selector(name)
      @selectors ||= {}
      @selectors[name.to_s] ||= MessageSelector.new([type(name)], repository: @repository)
      return @selectors[name.to_s]
    end

    # 台本の type すべて。⚠ 記念日の登録漏れ検査に使う。
    def types
      return ['eve', 'open', 'mc', 'close'].map {|name| type(name)}
    end

    private

    # ⚠⚠ **台本の type が記念日に登録されていなければ、作らせずに止める。**
    # 登録が無いと日付を持たない台本が段 4 / 5（季節・無指定）に混ざり、
    # ⚠ **ライブの原稿が毎日出る。**⚠ 出てしまってから気付く壊れ方なので、
    # 設定の側で止める（→ `Announcement#validate` と同じ判断）。
    def validate
      reserved = selector('open').reserved_types
      missing = types.reject {|name| reserved.include?(name)}
      return if missing.empty?
      raise Ginseng::ConfigError,
        "live: type '#{missing.join("', '")}' must be registered in /message/anniversary"
    end
  end
end
