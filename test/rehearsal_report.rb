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
    # 🔴 **再送しない失敗（ReadTimeout）の行**（#420）。⚠⚠ **実機では未観測** — **`ginseng-core` の
    # `RetryMethods#log_retry_error` が `count:` 無しで出す形をコードから組んだ**（`count` は nil）。
    TIMEOUT = '{"error":{"message":"Net::ReadTimeout with #<TCPSocket:(closed)>"},"method":"GET","url":"https://cure-api.example/api/v1/songs","start":"2026-11-04T03:02:00Z","count":null}'.freeze
    # ⚠ **マスクが空の値を落とした形**（`Ginseng::Masking#mask` は `to_s` が空の値を捨てる）。
    TIMEOUT_BARE = '{"error":{"message":"Net::ReadTimeout"},"method":"POST","url":"https://st2.precure.ml/api/v1/statuses","start":"2026-11-04T03:02:00Z"}'.freeze
    # ⚠ **所要の長い 1 本**（#201）。🔴 **`seconds` は `ginseng-core` の `HTTP#log` が入れる。**
    HTTP_SLOW = '{"method":"POST","url":"https://st2.precure.ml/api/v1/statuses","status":200,"seconds":9.0}'.freeze
    # ⚠ **メソッドが混ざること自体を固定する**（🔴 **#201 の 1 回目の数え直しは GET 2 本の
    # 混入だった** — ⚠⚠ **`0.275` は投稿ではなく `verify_credentials`**）。
    HTTP_GET = '{"method":"GET","url":"https://st2.precure.ml/api/v1/accounts/verify_credentials","status":200,"seconds":0.275}'.freeze
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

    # 🔴 **投稿が成功したときの 1 行**（`MastodonService#post_status`）。
    # ⚠⚠ **`url` を持つが `method` は持たない**ので、**HTTP の行としては数えない。**
    # ⚠ **`proxy_added` はモロヘイヤが足した字数**（#351）。
    POST_LOG = '{"mastodon":"post","status_id":"114514","url":"https://st2.precure.ml/@test/114514",' \
      '"visibility":"public","length":5,"post_length":5,"proxy_added":%d,"mulukhiya":true}'.freeze
    # ⚠ **迂回した回**（🔴 **モロヘイヤが何もしていないので測る対象が無い**）。
    POST_BYPASS = '{"mastodon":"post","status_id":"114514","url":"https://st2.precure.ml/@test/114514",' \
      '"visibility":"public","length":5,"post_length":5,"proxy_added":null,"mulukhiya":false}'.freeze

    def post_log(added)
      return POST_LOG % added
    end

    def report(*lines)
      return RehearsalReport.new(lines)
    end

    # ⚠ **予約の値を差し替える**（🔴 **既定 0 の窓を作るため**）。
    def with_proxy_reserve(value)
      original = config['/mastodon/proxy_reserve']
      config['/mastodon/proxy_reserve'] = value
      yield
    ensure
      config['/mastodon/proxy_reserve'] = original
    end

    # 🔴 **モロヘイヤが足した字数を貯める**（#351）。
    def test_the_lengths_the_proxy_added_are_collected
      subject = report(post_log(12), post_log(40), post_log(14)).proxy_added

      assert_equal({count: 3, min: 12, median: 14, max: 40}, subject)
    end

    # 🔴 **整数の中央 2 つを切り捨てない**（Codex の P2）。⚠⚠ **`/ 2` は整数除算**なので、
    # **12 と 13 の中央が 12 になっていた** — ⚠ **162 本のうち中央 2 つが違う回で必ず偏る。**
    def test_the_median_of_two_integer_samples_keeps_the_half
      assert_in_delta(12.5, report(post_log(12), post_log(13)).proxy_added[:median], 0.0001)
    end

    # ⚠ **迂回した回は入らない**（🔴 **「足されなかった」ではなく「測っていない」**）。
    def test_a_bypassed_post_carries_no_proxy_added
      assert_nil(report(POST_BYPASS).proxy_added)
    end

    # 🔴🔴 **歯止めの警告を集計へ入れない**（Codex の P2）。
    #
    # ⚠⚠ **`proxy_added` が負になったときの `warn` も `mastodon: 'post'` を持つ** —
    # ⚠ **同じ欄名で出すと、捨てたはずの負の値が分布へ入る**（**歯止めが自分で流し込む形**）。
    # 🔴 **出す側は欄名を分けたが、数える側も `status_id` と非負を要求する。**
    POST_NEGATIVE = '{"mastodon":"post","message":"proxy_added is negative","rejected_length":-3}'.freeze
    # ⚠ **万一、負の値が `proxy_added` の欄で来ても数えない**（数える側だけで成り立つこと）。
    POST_NEGATIVE_FIELD = '{"mastodon":"post","status_id":"114514","proxy_added":-3}'.freeze

    def test_a_rejected_negative_sample_does_not_enter_the_distribution
      assert_nil(report(POST_NEGATIVE).proxy_added)
      assert_nil(report(POST_NEGATIVE_FIELD).proxy_added)
      assert_equal(
        {count: 1, min: 12, median: 12, max: 12},
        report(POST_NEGATIVE, POST_NEGATIVE_FIELD, post_log(12)).proxy_added,
      )
    end

    # 🔴 **予約が 0 のときも印を付ける**（Codex の P2）。⚠⚠ **`/mastodon/proxy_reserve` は
    # `optional_config` の既定 0** なので、**設定が落ちた窓では予約ゼロ** — ⚠ **足された分が
    # 1 字でも上限を食う ＝ いちばん見たい状態。**
    def test_the_proxy_added_line_marks_going_over_a_zero_reserve
      with_proxy_reserve(0) do
        assert_include(report(post_log(12)).to_s, '⚠ モロヘイヤが足した字数: 1 本')
        assert_include(report(post_log(12)).to_s, '（予約 0）')
      end
    end

    # 🔴 **一部だけ測れた回を「測れた」と読ませない**（Codex の P2）。
    # ⚠⚠ **分布に最大が居るとは限らない。**
    def test_a_partially_measured_run_says_so
      subject = report(post_log(12), POST_BYPASS)

      assert_equal(1, subject.proxy_added[:count])
      assert_equal(1, subject.proxy_skipped)
      assert_include(subject.to_s, '1 本は測れていない')
      assert_include(subject.to_s, '復元できない形は測れない')
    end

    # ⚠ **1 本も測れなかった回は本数だけ出す。**
    def test_a_run_with_no_measurable_post_says_so
      subject = report(POST_BYPASS, POST_BYPASS)

      assert_nil(subject.proxy_added)
      assert_equal(2, subject.proxy_skipped)
      assert_include(subject.to_s, '1 本も測れていない（2 本）')
    end

    # ⚠ **`method` を持たないので HTTP の行としては数えない**（🔴 **`url` は持っている**）。
    def test_a_post_log_line_is_not_counted_as_http
      assert_empty(report(post_log(12)).http)
    end

    # ⚠ **予約（100 字）を超えたら印を付ける。**🔴 **ただし赤にはしない** —
    # **予約を超えただけでは投稿は落ちない**（落ちるのは 3000 字の上限を越えたとき）。
    # ⚠ **予約は設定から読む**ので、🔴 **テストでは固定する**（**実測で引き直した日に
    # このテストが黙って意味を変えないため** — 2026-09-24 に 100 → 300 にした）。
    def test_the_proxy_added_line_marks_going_over_the_reserve
      with_proxy_reserve(100) do
        assert_include(report(post_log(120)).to_s, '⚠ モロヘイヤが足した字数: 1 本')
        assert_include(report(post_log(12)).to_s, 'モロヘイヤが足した字数: 1 本 / min 12')
        assert_not_include(report(post_log(12)).to_s, '⚠ モロヘイヤが足した字数')
      end
    end

    # 🔴 **測れなかった回は「読めないもの」に名指しする**（#351）。
    def test_the_blind_spots_name_the_proxy_when_it_was_not_measured
      assert_include(report(POST_BYPASS).to_s, '復元できない形は測れない → #351')
      assert_not_include(report(post_log(12)).to_s, '復元できない形は測れない')
    end

    # 🔴 **履歴の通知を `exec` として数えないこと**（#284・Codex の P2）。
    #
    # ⚠⚠ **この行も `post` と `slot` を両方持つ**ので、⚠ **素で数えると成功した 1 枠が
    # exec 2 回になり、`anomalous_slots` に落ちて赤になる** — 🔴 **毎リリースの結合
    # テストが、正常な回で落ちることになる**（→ docs のリリース手順 4）。
    def test_a_notify_entry_is_not_an_exec
      subject = report(SUCCESS, NOTIFY, HEARTBEAT)

      assert_equal(1, subject.slots.size)
      assert_equal(1, subject.slots.values.first[:execs])
      assert_equal(1, subject.posted)
      assert_empty(subject.anomalous_slots)
      assert_false(subject.red?)
    end

    # 🔴 **黙る日の 1 行も `exec` に数えない**（#277）。⚠⚠ **11/3・11/4 を回すリハーサルで、
    # 曲紹介の枠が「exec があるのに投稿されていない」に見えないこと。**
    def test_a_quiet_entry_is_not_an_exec
      subject = report(SUCCESS, QUIET, HEARTBEAT)

      assert_equal(1, subject.slots.size)
      assert_empty(subject.anomalous_slots)
      assert_false(subject.red?)
    end

    # ⚠ **覚えなかった回も投稿の失敗ではない**（#284）。🔴 **履歴を切ってあれば毎回出る。**
    def test_a_notify_miss_is_not_a_failure
      subject = report(SUCCESS, NOTIFY_MISS, HEARTBEAT)

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
      subject = report(SUCCESS, HEARTBEAT)

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

    # 🔴 **1 本あたりの所要をメソッドごとに出す**（#201 の 1.）。
    #
    # ⚠⚠ **メソッドで割る。**🔴 **#201 の 1 回目の集計は GET 2 本を混ぜていて、
    # 「投稿 1 本の最小」が `verify_credentials` の `0.275` になっていた**（2026-08-29 に
    # 数え直した）— ⚠ **手で `grep` するかぎり毎回同じ取り違えが起きる。**
    def test_durations_are_grouped_by_method
      subject = report(HTTP_OK, HTTP_500, HTTP_SLOW, HTTP_GET).http_durations

      assert_equal(3, subject['POST'][:count])
      assert_in_delta(0.1, subject['POST'][:min], 0.0001)
      assert_in_delta(0.447, subject['POST'][:median], 0.0001)
      assert_in_delta(9.0, subject['POST'][:max], 0.0001)
      assert_equal(1, subject['GET'][:count])
      assert_in_delta(0.275, subject['GET'][:min], 0.0001)
    end

    # ⚠ **偶数本は中央 2 つの平均**（`(0.1 + 0.447) / 2`）。
    def test_the_median_of_an_even_count_is_the_middle_two
      subject = report(HTTP_500, HTTP_OK).http_durations

      assert_in_delta(0.274, subject['POST'][:median], 0.0001)
    end

    # 🔴 **落ちた試行の行は `seconds` を持たない**が、⚠⚠ **再送のあとに成功した行の `seconds` は
    # 落ちた試行と待ちを含む**（#420・`repeat` は `retry` しても `start` を取り直さない）。
    # 🔴 **だから「現れない」ではなく「max がふくらむ」と書く。**
    def test_retries_inflate_the_duration
      subject = report(RETRY, RETRY)

      assert_empty(subject.http_durations)
      assert_include(subject.to_s, '再送のあとに成功した行は')
      assert_not_include(subject.to_s, '再送で食った時間')
      assert_not_include(report(HTTP_OK).to_s, '再送のあとに成功した行は')
    end

    # 🔴 **再送しない失敗（ReadTimeout）は赤**（#420・2026-09-26 オーナー判断）。
    # ⚠⚠ **同じ GET が 503 なら赤、タイムアウトなら緑と割れていた**（`count` が偽なので応答の行に
    # `[method, nil]` で数えていた）。⚠ **再送ではないので `retries` にも入れない。**
    def test_a_timeout_is_red
      subject = report(TIMEOUT, TIMEOUT_BARE, HTTP_OK, HEARTBEAT, SUCCESS)

      assert_equal({'GET' => 1, 'POST' => 1}, subject.http_failures)
      assert_nil(subject.http[['GET', nil]])
      assert_nil(subject.http[['POST', nil]])
      assert_equal(0, subject.retries)
      assert_true(subject.red?)
      assert_include(subject.to_s, '🔴 GET 応答が返らなかった')
      assert_false(report(HTTP_OK, HEARTBEAT, SUCCESS).red?)
    end

    # 🔴🔴 **早送りの回の `seconds` は見かけ**（2026-09-23 に実測）。⚠⚠ **`HTTP#log` は
    # `Time.now` の差で秒を作り、`Timecop.thread_safe` の既定は `false`** なので、
    # **投稿を投げる別スレッドにも scale が効く。**
    # 🔴 **実時間として読むと、そこへもう一度 scale を掛けることになる** — ⚠ **docs も #201 も
    # 「中央値 6.772 秒 ＝ 見かけ 67 秒」と書いていたが、6.772 秒がすでに見かけ。**
    def test_durations_are_labelled_as_apparent_time_when_scaled
      subject = report(TRAVEL, HTTP_SLOW).to_s

      assert_include(subject, 'POST の所要（見かけ）: 1 本 / min 9.0 / median 9.0 / max 9.0 秒')
      assert_include(subject, 'POST の所要（実時間）: min 0.9 / median 0.9 / max 0.9 秒')
    end

    # ⚠ **等速の回は見かけと実時間が同じ**なので、🔴 **名乗りも割り算も出さない。**
    def test_durations_are_not_relabelled_when_not_scaled
      subject = report(HTTP_SLOW).to_s

      assert_include(subject, 'POST の所要: 1 本 / min 9.0 / median 9.0 / max 9.0 秒')
      assert_not_include(subject, '見かけ')
      assert_not_include(subject, '（実時間）')
    end

    # 🔴 **弾いたときの 1 行は要約ではない**（#417）。⚠⚠ **`time_travel` の値が文字列**なので、
    # **要約として拾うと見出しの組み立てが落ちる。**
    def test_a_refused_time_travel_is_not_taken_as_the_summary
      refused = '{"time_travel":"refused","error":{"message":"time travel: bad MAKOTO_TIME_SCALE"}}'
      subject = report(refused, TRAVEL, SUCCESS)

      assert_equal(10, subject.travel[:scale])
      assert_nothing_raised {report(refused, SUCCESS).to_s}
      # 🔴 **捨てずに赤にする**（#418 の Codex の P1）。⚠⚠ **弾かれた回は常駐が起きていない**ので、
      # **他の行が通っていても緑にしない** — ⚠ **受け皿に入らなかった `error` 行として拾う**（#416）。
      refused_run = report(refused, TRAVEL, HEARTBEAT, SUCCESS)

      assert_equal({'time_travel:refused' => 1}, refused_run.unclassified)
      assert_true(refused_run.red?)
    end

    # 🔴 **登録を見送った投稿は赤**（#416 / #350）。⚠⚠ **実機が出す 2 行をそのまま写した** —
    # **どちらも `slot` を持たないので、受け皿が無かった頃は捨てていた**（**`live` の 160 枠が
    # 丸ごと無くても、他の枠が通れば緑**）。
    def test_a_rejected_post_is_red
      daemon = '{"daemon":"MakotoDaemon","post":"live","error_class":"Ginseng::ConfigError",' \
        '"error":{"message":"live: bad timetable"}}'
      reject = '{"scheduler":"reject","post":"live","reason":"live: bad timetable"}'
      subject = report(daemon, reject, HEARTBEAT, SUCCESS)

      assert_equal([{post: 'live', reason: 'live: bad timetable'}], subject.rejects)
      assert_true(subject.red?)
      assert_include(subject.to_s, '🔴 live: live: bad timetable')
    end

    # 🔴🔴 **どの受け皿にも入らなかった `error` 行は赤**（#416）。⚠⚠ **行の形を足すと集計が黙る
    # 構造**を 4 回踏んだ（#284 / #348 / #351 / #416）ので、**最後に拾う。**
    # ⚠ **実機が出す形**: 投稿の痕跡が書けない（`PostingJob`）／tick の例外（`Scheduler`）／
    # 履歴の書き込み失敗（`TrackHistory`）。
    def test_error_lines_without_a_counter_are_red
      lines = [
        '{"post":"song","heartbeat":"success","error":{"message":"EACCES"}}',
        '{"scheduler":"tick","post":"song","error":{"message":"boom"}}',
        '{"scheduler":"tick","error":{"message":"boom"}}',
        '{"track":"history","post":"song","error":{"message":"database is locked"}}',
      ]
      subject = report(*lines, HEARTBEAT, SUCCESS)

      assert_equal({'post:song' => 1, 'scheduler:tick post:song' => 1, 'scheduler:tick' => 1,
        'track:history post:song' => 1}, subject.unclassified)
      assert_true(subject.red?)
      assert_include(subject.to_s, '🔴 track:history post:song: 1 行')
    end

    # 🔴 **投稿の行でも、`status_id` が無く `error` を持つなら受け皿へ**（#419 の Codex の P2）。
    # ⚠ **`proxy_added` の計測が落ちた行**（`MastodonService#proxy_added` の `rescue`）。
    def test_a_failed_proxy_measurement_is_not_dropped
      failed = '{"mastodon":"post","message":"proxy_added failed","error":"NoMethodError"}'
      negative = '{"mastodon":"post","message":"proxy_added is negative","rejected_length":-3}'
      subject = report(failed, negative, HEARTBEAT, SUCCESS)

      assert_equal({'mastodon:post' => 1}, subject.unclassified)
      assert_true(subject.red?)
    end

    # ⚠ **`error` を持たない行は拾わない**（登録・黙る日・「新しい曲が残っていない」の warn）。
    def test_lines_without_an_error_stay_out_of_the_unclassified
      nothing = '{"track":"history","post":"song","size":3,"message":"nothing fresh left"}'
      subject = report(nothing, REGISTER, QUIET, HEARTBEAT, SUCCESS)

      assert_empty(subject.unclassified)
      assert_false(subject.red?)
      assert_not_include(subject.to_s, '受け皿に入らなかった')
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

    # 🔴 **空のログは赤**（#416）。⚠⚠ **`--since` の打ち間違い・unit 名の誤り・起動で落ちた回で
    # 0 行になる** — ⚠ **「何も落ちていない」ではなく「何も見ていない」。**
    def test_an_empty_log_is_red
      subject = report

      assert_true(subject.red?)
      assert_include(subject.to_s, '🔴 枠が 1 つも無い')
    end

    # 🔴 **ハートビートが 0 回でも赤**（#416）。⚠ **常駐が起きていないか、別の unit を読んでいる。**
    def test_no_heartbeat_is_red
      assert_true(report(SUCCESS).red?)
      assert_false(report(SUCCESS, HEARTBEAT).red?)
      assert_include(report(SUCCESS).to_s, '🔴 ハートビートが 1 回も無い')
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
      subject = report(SILENCE, HEARTBEAT)

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

    # 🔴 **赤にする**（#368・2026-09-19 オーナー判断で #92 の線を引き直した）。
    # ⚠⚠ **`warn_slow` は `CLOCK_MONOTONIC` で測り予算も実秒**なので、**この行が出たら
    # 早送りでも実時間で本当に予算を超えている。**⚠ **打ち切らない判断はそのまま**
    # （`Timeout.timeout` は二重投稿の入口 → #92）で、**「合否に数えない」線だけを動かした。**
    def test_a_slow_entry_is_red
      assert_true(report(SUCCESS, SLOW).red?)
    end

    # 🔴 **早送りを「割引」と読ませない**（#348・Codex の P2 の 3 巡目）。⚠⚠ **`warn_slow` は
    # `CLOCK_MONOTONIC` で測り、予算も実秒**なので、**`Timecop.scale` はこの数字を動かさない** —
    # ⚠ **伸びるのは予定の側**（同じ所要が枠の scale 倍を食う → #90）。
    def test_a_slow_entry_does_not_blame_the_scale
      assert_include(report(TRAVEL, SUCCESS, SLOW).to_s, '計測は実時間（monotonic）')
      assert_not_include(report(SUCCESS, SLOW).to_s, '計測は実時間（monotonic）')
    end

    # ⚠ **計測そのものが落ちた行は別に数える**（#348）。🔴 **`slot` を持たないので
    # 投稿の失敗にも数えない。**
    def test_a_slow_measurement_error_is_counted_separately
      subject = report(SUCCESS, SLOW_ERROR)

      assert_equal(1, subject.slow_errors)
      assert_empty(subject.slows)
      assert_equal(0, subject.failed)
      assert_include(subject.to_s, '計測そのものが 1 回落ちた')
      # 🔴 **これも赤**（#368）。⚠⚠ **測れていない窓は、この集計が嘘をつきうる窓。**
      assert_true(subject.red?)
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
    # ⚠⚠ **残っているのは `recorded:false` だけ**（🔴 **`slow` は #368 で赤に移った**）。
    def test_the_blind_spot_names_what_is_not_red
      subject = report(SUCCESS)

      assert_include(subject.to_s, 'recorded:false は赤にしない')
      assert_not_include(subject.to_s, '予算を超えた枠と')
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

    # 🔴 **落ちた tick を 2 回に数えない**（#362）。⚠⚠ **`Scheduler#schedule_heartbeat` は
    # 1 回の tick で 2 行出しうる**（情報の行が先に出て、`Heartbeat.touch` が落ちたら
    # `error` の行も出る）— ⚠ **報告書は「回」と書くので、行のまま数えると嘘になる。**
    def test_a_heartbeat_error_is_not_counted_as_a_heartbeat
      subject = report(HEARTBEAT_REV, HEARTBEAT_ERROR)

      assert_equal(1, subject.heartbeats)
      assert_equal(1, subject.heartbeat_errors)
      assert_include(subject.to_s, 'ハートビート: 1 回')
    end

    # 🔴 **痕跡が書けなかったことを名指しする**（#362）。⚠⚠ **数えなかった頃は完全に無言で、
    # 全部書けた回と出力が 1 文字も変わらなかった。**
    def test_a_heartbeat_error_is_named_in_the_report
      assert_include(report(HEARTBEAT_REV, HEARTBEAT_ERROR).to_s, '痕跡の書き込みが 1 回落ちた')
    end

    # 🔴 **赤にする**（#362・2026-09-19 オーナー判断）。⚠⚠ **痕跡は `/healthz` が読むもの**
    # なので、**書けていない間は死活監視が古い値を見ている ＝ 監視が盲目。**
    # ⚠ **`Heartbeat` が fail-open で常駐を止めないこととは両立する** — 🔴 **止めない設計と、
    # リハーサルの合否は別。**
    def test_a_heartbeat_error_is_red
      assert_true(report(SUCCESS, HEARTBEAT_ERROR).red?)
      assert_false(report(SUCCESS, HEARTBEAT_REV).red?)
    end
  end
end
