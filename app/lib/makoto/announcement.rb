module Makoto
  # 11/1 からの予告投稿（#14）。バースデーライブ（#13）の助走にあたる。
  # ⚠ **予告開始が 11/1 なので、機能的な締め切りは 11/4 ではなくこちら**
  # （→ [birthday-live.md](../../../docs/birthday-live.md)）。ライブ本体より先に動く。
  #
  # ⚠⚠ **日付を枠に持たせない。**枠は毎日あり、その日の原稿が無ければ
  # `MessageSelector` が nil を返して**何も投稿しない**。⚠ **予告の日付は原稿の側
  # （`makoto message add --date=2026-11-01`）と `/message/anniversary` が持つ**ので、
  # 日付を動かすのにコード変更もデプロイも要らない（#12 の完了条件）。
  # ⚠ **止めるのも原稿を消すだけ**でよいので、機能フラグを持たない。
  #
  # ⚠ **枠は 1 日 1 本。**11/3 の増量（→ [birthday-live.md](../../../docs/birthday-live.md)）は
  # この枠を広げるのではなく、#13 が別の枠として足す。⚠⚠ **枠は日付を区別しないので、
  # 広げると 11/1 と 11/2 も一緒に増える。**
  class Announcement
    include Package

    PREFIX = '/announcement'.freeze

    # ⚠ **冪等キーの前半になるので動かさない**（`announcement-{枠の時刻 UTC}`）。
    # 原稿の type を変えてもキーが変わらないよう、type とは別に持つ。
    NAME = 'announcement'.freeze

    # @param repository [MessageRepository] テストが差し替えるためだけの口
    def initialize(repository: nil)
      @repository = repository
    end

    def type
      return config["#{PREFIX}/type"].to_s
    end

    def timetable
      @timetable ||= Timetable.new(
        start: config["#{PREFIX}/timetable/start"],
        finish: config["#{PREFIX}/timetable/finish"],
        interval: config["#{PREFIX}/timetable/interval"],
      )
      return @timetable
    end

    def source
      @source ||= MessageSelector.new([type], repository: @repository)
      return @source
    end

    def job
      validate
      return PostingJob.new(name: NAME, timetable: timetable, source: source)
    end

    private

    # ⚠⚠ **予告の type が記念日に登録されていなければ、作らせずに止める。**
    # 登録が無いと `MessageSelector` の段 4 / 5（季節・無指定）に予告の原稿が混ざり、
    # ⚠ **11/1〜11/3 だけのはずの予告が毎日出る**。⚠ 出てしまってから気付く壊れ方
    # なので、設定の側で止める（→ `MessageSelector` の「記念日の type はその日以外
    # では選ばれない」）。
    def validate
      return if source.anniversary_types.value?(type)
      raise Ginseng::ConfigError,
        "announcement: type '#{type}' must be registered in /message/anniversary"
    end
  end
end
