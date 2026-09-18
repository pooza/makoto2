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
    # 🔴 **`post` と `slot` を両方持つが `exec` ではない**（#284 → `PostingJob#notify`）。
    NOTIFY = '{"post":"song","slot":"2026-11-04T03:02:00Z","phase":"notify","recorded":true}'.freeze
    NOTIFY_MISS = '{"post":"song","slot":"2026-11-04T03:02:00Z","phase":"notify","recorded":false}'.freeze
    NOTIFY_ERROR = '{"error":{"message":"boom"},"post":"song","slot":"2026-11-04T03:02:00Z","phase":"notify"}'.freeze

    # 🔴 **予算を超えて長くかかった枠の 1 行**（#92 → `PostingJob#warn_slow`）。
    # ⚠⚠ **`post` と `slot` を両方持つ**ので、**捨てないと `exec` 2 回になる**（#348）。
    SLOW = '{"post":"song","slot":"2026-11-04T03:00:00Z","phase":"slow","seconds":12.3,"budget":9.0}'.freeze
    # ⚠ **計測そのものが落ちた行**（`warn_slow` の `rescue`）。🔴 **`slot` を持たない。**
    SLOW_ERROR = '{"error":{"message":"boom"},"post":"song","phase":"slow"}'.freeze
    # ⚠ **`revision` を持つハートビート**（#242 → `MakotoDaemon`）。
    HEARTBEAT_REV = '{"scheduler":"heartbeat","version":"0.6.0","revision":"689b795","jobs":7}'.freeze
    # 🔴 **痕跡の書き込みが落ちた行**（`Scheduler#schedule_heartbeat` の `rescue`）。
    # ⚠⚠ **版もリビジョンも持たない。**
    HEARTBEAT_ERROR = '{"error":{"message":"boom"},"scheduler":"heartbeat"}'.freeze

    # 🔴 **黙る日に黙ったことの 1 行**（#277 → `SongSource#log_quiet_day`）。⚠ **これも `exec` ではない。**
    QUIET = '{"post":"song","slot":"2026-11-04T03:00:00Z","phase":"quiet","message":"quiet day","types":["live_open","live_close"]}'.freeze

    def report(*lines)
      return RehearsalReport.new(lines)
    end

    # 🔴 **履歴の通知を `exec` として数えないこと**（#284・Codex の P2）。
    #
    # ⚠⚠ **この行も `post` と `slot` を両方持つ**ので、⚠ **素で数えると成功した 1 枠が
    # exec 2 回になり、`anomalous_slots` に落ちて赤になる** — 🔴 **毎リリースの結合
    # テストが、正常な回で落ちることになる**（→ docs のリリース手順 4）。
    def test_a_notify_entry_is_not_an_exec
      subject = report(SUCCESS, NOTIFY)

      assert_equal(1, subject.slots.size)
      assert_equal(1, subject.slots.values.first[:execs])
      assert_equal(1, subject.posted)
      assert_empty(subject.anomalous_slots)
      assert_false(subject.red?)
    end

    # 🔴 **黙る日の 1 行も `exec` に数えない**（#277）。⚠⚠ **11/3・11/4 を回すリハーサルで、
    # 曲紹介の枠が「exec があるのに投稿されていない」に見えないこと。**
    def test_a_quiet_entry_is_not_an_exec
      subject = report(SUCCESS, QUIET)

      assert_equal(1, subject.slots.size)
      assert_empty(subject.anomalous_slots)
      assert_false(subject.red?)
    end

    # ⚠ **覚えなかった回も投稿の失敗ではない**（#284）。🔴 **履歴を切ってあれば毎回出る。**
    def test_a_notify_miss_is_not_a_failure
      subject = report(SUCCESS, NOTIFY_MISS)

      assert_equal(0, subject.failed)
      assert_false(subject.red?)
    end

    # 🔴 **通知が落ちた回は赤のまま**（#284）。
    #
    # ⚠⚠ **この行が無かった頃は `post` と `slot` と `error` を持つ 1 行として `failed` に
    # 数えられ、`red?` に掛かっていた** — ⚠ **区別を足したついでに見逃す形にしない**
    # （**投稿は出たのに履歴が伸びていない** ＝ **#41 の重複回避が切れている**）。
    def test_a_notify_failure_is_still_red
      subject = report(SUCCESS, NOTIFY_ERROR)

      assert_equal(1, subject.notify_failures)
      assert_true(subject.red?)
      # ⚠ **投稿の失敗としては数えない**（投稿そのものは出ている）。
      assert_equal(0, subject.failed)
      assert_equal(1, subject.slots.values.first[:execs])
    end

    # ⚠⚠ **赤にした理由を本文にも書く**（#127 と同じ）。
    def test_a_notify_failure_is_named_in_the_report
      assert_include(report(SUCCESS, NOTIFY_ERROR).to_s, '通知が落ちた')
      # 🔴 **1 行も無いのが普通**（`posted` を持つのは曲紹介だけ）なので、節ごと出さない。
      assert_not_include(report(SUCCESS).to_s, '履歴の通知')
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

    # 🔴 **応答を伴わない失敗も赤**（#127・Codex の指摘）。⚠⚠ **`source` の例外・名前解決・
    # タイムアウトは `{"post":…,"slot":…,"error":…}` の 1 行しか残さない**ので、
    # ⚠ **枠あたりの exec は 1 回のまま・`status_id` も無い・HTTP の行も出ない。**
    # **枠が落ちているのに終了コード 0 で通っていた。**
    def test_a_failed_slot_alone_is_red
      subject = report(FAILURE)

      assert_equal(1, subject.failed)
      assert_equal(0, subject.http_errors)
      assert_true(subject.anomalous_slots.empty?)
      assert_true(subject.duplicated_slots.empty?)
      assert_true(subject.red?)
      # ⚠⚠ **赤にした理由が本文にも出ること**（終了コードだけ赤にしない）。
      assert_include(subject.to_s, '🔴 1 回の投稿が落ちた')
    end

    # ⚠ **沈黙は赤にしない。**⚠⚠ **「今日は投稿しない」であって失敗ではない。**
    def test_a_silent_slot_is_not_red
      subject = report(SILENCE)

      assert_equal(0, subject.failed)
      assert_false(subject.red?)
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

    # 🔴 **予算を超えた枠の行を `exec` に数えない**（#348）。⚠⚠ **`notify` と同じ形**
    # （`post` と `slot` を両方持つ）なので、**素で数えると成功した 1 枠が exec 2 回になる。**
    def test_a_slow_entry_is_not_an_exec
      subject = report(SUCCESS, SLOW)

      assert_equal(1, subject.slots.size)
      assert_equal(1, subject.slots.values.first[:execs])
      assert_empty(subject.anomalous_slots)
      assert_equal(1, subject.slows.size)
    end

    # 🔴 **捨てずに受け皿へ入れる**（#348）。⚠⚠ **#92 で出した行が丸ごと消えていたので、
    # #90（枠を跨ぐ余裕が構造的にゼロ）が再発しても報告書は緑のままだった。**
    def test_a_slow_entry_is_named_in_the_report
      subject = report(SUCCESS, SLOW)

      assert_include(subject.to_s, '予算を超えた枠: 1 回')
      assert_include(subject.to_s, '12.3 秒（予算 9.0 秒）')
    end

    # 🔴 **赤にはしない**（#348 / #92）。⚠⚠ **早送りでは実時間が伸びる**ので、
    # **赤にすると毎回鳴る** — ⚠ **#92 は「観測まで」で線を引いている。**
    def test_a_slow_entry_is_not_red
      assert_false(report(SUCCESS, SLOW).red?)
    end

    # ⚠ **早送りの回は「この節は赤ではない」と書く**（#348）。🔴 **読む人が「本番でも
    # 遅い」と取り違えないため。**
    def test_a_slow_entry_notes_the_scale
      assert_include(report(TRAVEL, SUCCESS, SLOW).to_s, '早送り中は実時間が伸びる')
      assert_not_include(report(SUCCESS, SLOW).to_s, '早送り中は実時間が伸びる')
    end

    # ⚠ **計測そのものが落ちた行は別に数える**（#348）。🔴 **`slot` を持たないので
    # 投稿の失敗にも数えない。**
    def test_a_slow_measurement_error_is_counted_separately
      subject = report(SUCCESS, SLOW_ERROR)

      assert_equal(1, subject.slow_errors)
      assert_empty(subject.slows)
      assert_equal(0, subject.failed)
      assert_include(subject.to_s, '計測そのものが 1 回落ちた')
    end

    # 🔴 **`recorded: false` を数えて名指しする**（#348）。⚠⚠ **数えなかった頃は、
    # 全部 `true` だった回と出力が 1 文字も変わらなかった** — ⚠ **`recorded: false` は
    # 「投稿は出たのに履歴が伸びていない」＝ #41 の重複回避が無言で切れた状態。**
    def test_a_notify_miss_is_named_in_the_report
      subject = report(SUCCESS, NOTIFY_MISS)

      assert_equal(1, subject.notify_misses)
      assert_include(subject.to_s, '1 回が履歴を伸ばさなかった（recorded:false）')
    end

    # ⚠ **数えているが赤にしないものを「読めないもの」に書く**（#348）。
    # 🔴 **終了コードだけを見る人に、節が出ていることを知らせる。**
    def test_the_blind_spot_names_what_is_not_red
      assert_include(report(SUCCESS).to_s, '赤にしない')
    end

    # ⚠ **リビジョンを見出しに出す**（#348 / #242）。🔴 **`version` は `0.6.0` のまま
    # 何コミットでも進む**ので、**版だけでは「その修正が載っているか」に答えられない。**
    def test_the_header_shows_the_revision
      subject = report(HEARTBEAT_REV)

      assert_equal(['689b795'], subject.revisions.to_a)
      assert_include(subject.to_s, 'リビジョン 689b795')
    end

    # 🔴 **途中でデプロイが挟まった回を見出しで言う**（#348）。⚠⚠ **結果を 1 つの版の
    # ものとして読めない** — ⚠ **#242 が消したかった盲点がここに残っていた。**
    def test_a_revision_change_is_flagged
      subject = report(HEARTBEAT_REV, HEARTBEAT_REV.sub('689b795', 'a12eca8'))

      assert_equal(2, subject.revisions.size)
      assert_include(subject.to_s, '途中でリビジョンが変わった（2 種）')
    end

    # ⚠ **リビジョンを持たない古いログでも落ちない**（#348）。🔴 **`0.6` より前の
    # リハーサルのログを流し込む形は残っている。**
    def test_a_log_without_a_revision_is_not_broken
      assert_include(report(HEARTBEAT).to_s, 'リビジョン (不明)')
    end

    # 🔴 **痕跡の書き込みが落ちた行を版として数えない**（#348・Codex の P2 の 2 巡目）。
    # ⚠⚠ **`(不明)` を足すと、1 つの版で通した回が「途中でリビジョンが変わった」に化ける。**
    def test_a_heartbeat_error_does_not_count_as_a_revision
      subject = report(HEARTBEAT_REV, HEARTBEAT_ERROR)

      assert_equal(['689b795'], subject.revisions.to_a)
      assert_not_include(subject.to_s, '途中でリビジョンが変わった')
    end

    # 🔴 **持つ行と持たない行が混ざった回を見逃さない**（#348・Codex の P2）。
    # ⚠⚠ **`revision` の無い行を捨てると、見出しが「全部この 1 つのリビジョン」に見え、
    # 警告も出ない** — ⚠ **#242 より前の版へ／から起き直した窓がこの形。**
    def test_a_log_mixing_revision_and_no_revision_is_flagged
      subject = report(HEARTBEAT, HEARTBEAT_REV)

      assert_equal(2, subject.revisions.size)
      assert_include(subject.to_s, '(不明)')
      assert_include(subject.to_s, '途中でリビジョンが変わった（2 種）')
    end
  end
end
