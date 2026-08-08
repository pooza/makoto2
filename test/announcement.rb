module Makoto
  class AnnouncementTest < TestCase
    def setup
      super
      @repository = MessageRepository.new(corpus_db)
    end

    def announcement
      return Announcement.new(repository: @repository)
    end

    def jst(month, day, hour = 10, year: 2026)
      return Time.new(year, month, day, hour, 0, 0, '+09:00')
    end

    # 予告の原稿を 1 本置く。⚠ **日付は原稿の側が持つ**（枠は日付を知らない）。
    def add(body, month:, day:, year: 2026)
      return @repository.create(
        type: config['/announcement/type'], body: body, year: year, month: month, day: day,
      )
    end

    # ⚠ 枠は 1 日 1 本。**`finish` は含まない（半開区間）**ので 10:00 だけ。
    # ⚠ 10:00 なのはニチアサ実況の流れが残っている時刻だから（→ config）。
    def test_timetable_has_one_slot_a_day
      times = announcement.timetable.times(Date.new(2026, 11, 1))

      assert_equal([jst(11, 1)], times)
    end

    def test_job
      job = announcement.job

      assert_equal(Announcement::NAME, job.name)
      assert_equal(announcement.timetable.to_s, job.timetable.to_s)
    end

    # ⚠ 冪等キーは枠の頭から作る。⚠⚠ **再起動で同じ枠をもう一度処理しても
    # Mastodon 側が畳む**（→ PostingJob）。
    def test_idempotency_key_comes_from_the_slot
      assert_equal('announcement-20261101T010000Z', announcement.job.idempotency_key(jst(11, 1)))
    end

    # ⚠⚠ #14 の完了条件。11/1 に予告が出ること。
    def test_announces_on_the_first_day
      add('11/4 はバースデーライブです', month: 11, day: 1)

      assert_equal('11/4 はバースデーライブです', announcement.source.call(jst(11, 1)))
    end

    # ⚠ 3 日ぶんが日付どおりに出し分かれること（同じ type でも別の原稿）。
    def test_each_day_has_its_own_message
      add('あと 3 日', month: 11, day: 1)
      add('あと 2 日', month: 11, day: 2)
      add('あと 1 日', month: 11, day: 3)
      source = announcement.source

      assert_equal(['あと 3 日', 'あと 2 日', 'あと 1 日'],
        [jst(11, 1), jst(11, 2), jst(11, 3)].map {|time| source.call(time)})
    end

    # ⚠⚠ **予告の無い日は何も投稿しない。**枠は毎日あるので、ここが nil を返さないと
    # 毎日予告が出る。⚠ ライブ当日（11/4）も予告ではないので出ない。
    def test_silent_on_other_days
      add('あと 3 日', month: 11, day: 1)
      source = announcement.source
      times = [jst(1, 1), jst(6, 15), jst(10, 31), jst(11, 4), jst(11, 5), jst(12, 24)]

      assert_equal([], times.filter_map {|time| source.call(time)})
    end

    # ⚠⚠ **日付を持たない予告の原稿があっても、予告の日以外には出ない。**記念日に
    # 登録した type は段 4 / 5（季節・無指定）から外れる（→ MessageSelector）。
    # ⚠ これが外れると「毎日予告が出る」形で表面化する。
    def test_undated_message_never_leaks_to_other_days
      @repository.create(type: config['/announcement/type'], body: '日付の無い予告')
      source = announcement.source

      assert_equal('日付の無い予告', source.call(jst(11, 2)))
      assert_nil(source.call(jst(6, 15)))
    end

    # ⚠⚠ **記念日に登録されていない type では作らせない。**登録が無いと予告が毎日
    # 出るが、それは 11/1 まで気付けない。⚠ 起動時に落とすほうが早い。
    def test_rejects_a_type_that_is_not_an_anniversary
      config['/announcement/type'] = 'teaser'

      assert_raise(Ginseng::ConfigError) {announcement.job}
    end

    def test_type_is_registered_as_an_anniversary
      assert_equal(['11-01', '11-02', '11-03'],
        announcement.source.anniversary_types.select {|_, type| type == announcement.type}.keys)
    end
  end
end
