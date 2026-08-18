module Makoto
  class RehearsalReportTest < TestCase
    # ⚠ **実機のログをそのまま写した形**（2026-08-18 の st2 リハーサル）。
    # ⚠⚠ **書式を推測で作らない** — 集計はログの形に完全に依存する。
    SUCCESS = '{"post":"live","slot":"2026-11-04T03:02:00Z","status_id":"117117073646276284"}'.freeze
    FAILURE = '{"error":{"message":"Bad response 500","file":"lib/ginseng/http.rb","line":70},"post":"live","slot":"2026-11-04T03:02:00Z"}'.freeze
    SILENCE = '{"post":"announcement","slot":"2026-11-04T01:00:00Z","message":"no text"}'.freeze
    HTTP_OK = '{"method":"POST","url":"https://st2.precure.ml/api/v1/statuses","status":200,"seconds":0.447}'.freeze
    HTTP_500 = '{"method":"POST","url":"https://st2.precure.ml/api/v1/statuses","status":500,"seconds":0.1}'.freeze
    RETRY = '{"error":{"message":"Bad response 500","file":"lib/ginseng/http.rb","line":70},"method":"POST","url":"https://st2.precure.ml/api/v1/statuses","count":2}'.freeze
    HEARTBEAT = '{"scheduler":"heartbeat","version":"0.3.0","jobs":5}'.freeze
    TRAVEL = '{"time_travel":{"start":"2026-11-04T11:55:00+09:00","scale":10,"mastodon":"st2.precure.ml"}}'.freeze
    # ⚠ **`slot` を持たないので exec には数えない。**
    REGISTER = '{"scheduler":"register","post":"live","timetable":"12:02-20:00/180s (Asia/Tokyo)"}'.freeze

    def report(*lines)
      return RehearsalReport.new(lines)
    end

    def test_counts_one_exec_per_line
      subject = report(SUCCESS)

      assert_equal(1, subject.slots.size)
      assert_equal(1, subject.posted)
      assert_true(subject.anomalous_slots.empty?)
      assert_false(subject.red?)
    end

    # 🔴 **これが本体。**#109 の形（1 枠が 3 回 exec され、2 回目以降が 500）。
    def test_three_execs_on_one_slot_is_red
      subject = report(SUCCESS, FAILURE, FAILURE)

      assert_equal(1, subject.slots.size)
      assert_equal(3, subject.slots.values.first[:execs])
      assert_equal(1, subject.posted)
      assert_equal(2, subject.failed)
      assert_equal(1, subject.anomalous_slots.size)
      assert_true(subject.red?)
    end

    # 🔴 **500 が止まった世界の壊れ方。**⚠⚠ **同じ枠から 2 件の status が出る。**
    def test_two_status_ids_on_one_slot_is_a_duplicate
      other = SUCCESS.sub('117117073646276284', '117117073646276285')
      subject = report(SUCCESS, other)

      assert_equal(1, subject.duplicated_slots.size)
      assert_equal(2, subject.posted)
      assert_equal(2, subject.unique_posts)
      assert_true(subject.red?)
    end

    # ⚠ **冪等キーが効いていれば同じ status_id が返る。**⚠⚠ **延べと実数を分ける。**
    def test_the_same_status_id_twice_is_not_a_duplicate
      subject = report(SUCCESS, SUCCESS)

      assert_true(subject.duplicated_slots.empty?)
      assert_equal(2, subject.posted)
      assert_equal(1, subject.unique_posts)
      # ⚠ **重複ではないが回数は異常**（2 回 exec されている）。
      assert_equal(1, subject.anomalous_slots.size)
    end

    # ⚠⚠ **`{"scheduler":"register","post":…}` は `slot` を持たないので混ざらない。**
    def test_register_lines_are_not_execs
      subject = report(REGISTER, SUCCESS)

      assert_equal(1, subject.slots.size)
    end

    def test_http_breakdown
      subject = report(HTTP_OK, HTTP_500, HTTP_500)

      assert_equal(1, subject.http[['POST', 200]])
      assert_equal(2, subject.http[['POST', 500]])
      assert_equal(2, subject.http_errors)
      assert_true(subject.red?)
    end

    # ⚠ **落ちた試行の行は `count` を持つ。**内訳に混ぜず、再送の回数として数える。
    def test_retry_lines_are_counted_separately
      subject = report(RETRY, RETRY)

      assert_equal(2, subject.retries)
      assert_true(subject.http.empty?)
      assert_equal(0, subject.http_errors)
    end

    def test_heartbeat_and_version
      subject = report(HEARTBEAT, HEARTBEAT)

      assert_equal(2, subject.heartbeats)
      assert_equal(['0.3.0'], subject.versions.to_a)
    end

    def test_time_travel
      subject = report(TRAVEL)

      assert_equal(10, subject.travel[:scale])
      assert_equal('st2.precure.ml', subject.travel[:mastodon])
      assert_include(subject.to_s, '日付を騙している')
    end

    # ⚠ **騙した痕跡が無いことも書く**（本番のログと取り違えないため）。
    def test_a_missing_travel_is_noted
      assert_include(report(SUCCESS).to_s, '日付を騙した痕跡が無い')
    end

    # ⚠⚠ **バックトレースは JSON でない素の行で出る。**⚠ 落ちずに捨てる。
    def test_non_json_lines_are_ignored
      subject = report('  /home/deploy/repos/makoto2/app/lib/makoto/http.rb:70:in `post`', SUCCESS)

      assert_equal(1, subject.slots.size)
      assert_equal(1, subject.lines)
    end

    def test_an_empty_log_is_not_red
      subject = report

      assert_false(subject.red?)
      assert_include(subject.to_s, '枠が 1 つも無い')
    end

    def test_silenced_slots_are_counted_when_the_level_shows_them
      subject = report(SILENCE)

      assert_equal(1, subject.silenced)
      assert_equal(0, subject.posted)
    end

    # 🔴 **読めていないものを毎回書く。**⚠⚠ **沈黙の 1 行が `debug` で消えている**
    # ことを、集計の側から言えるようにしておく（→ #114）。
    def test_the_blind_spot_names_the_silent_slots
      assert_include(report(SUCCESS).to_s, '#114')
      assert_not_include(report(SUCCESS, SILENCE).to_s, '#114')
    end

    # ⚠ **早送りしたときだけ「枠を跨ぐか」は測れないと書く**（#90 / #92）。
    def test_the_blind_spot_names_the_scale
      assert_include(report(TRAVEL).to_s, '#90')
      assert_not_include(report(TRAVEL.sub('"scale":10', '"scale":1')).to_s, '#90')
    end

    def test_by_name
      subject = report(SUCCESS, FAILURE, SILENCE)
      row = subject.by_name['live']

      assert_equal(1, row[:slots])
      assert_equal(2, row[:execs])
      assert_equal([2, 2], row[:range])
      assert_equal(1, subject.by_name['announcement'][:silences])
    end
  end
end
