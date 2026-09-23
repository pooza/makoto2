module Makoto
  # リハーサルのために**日付だけを騙す**仕掛け（#110）。
  #
  # ⚠⚠ **リハーサルは結合テストに相当する**（→ docs/CLAUDE.md リリース手順 4）。
  # ⚠ **11/4 が過ぎるまで毎リリース回す**ので、**毎回できるだけ安く・取り違えなく**
  # 回せる形にする。
  #
  # ## 🔴 DB も設定も台本も触らない
  #
  # ⚠⚠ **常駐が「今日は 11/4 だ」と信じれば、`2026-11-04` を持つ本番の台本が
  # そのまま引ける。**⚠ **セットリストの種も日付から作る**（`CoverSelector` の
  # `Random.new(date.strftime('%Y%m%d'))`）ので、**カバーの抽選まで本番と同一。**
  # ＝ **字義どおり「日付以外は全く同じ」。**
  #
  # ⚠ **記念日の登録をずらす形（`config/local.yaml` を書き換える）は採らない。**
  # 🔴 **戻し忘れると本番の台本が引けなくなる**うえ、⚠⚠ **枠を圧縮すると枠数が
  # 変わり、`Setlist` の埋め草（`枠数 − 曲数 − アンカー`）が本番と別物になる。**
  #
  # ## 早送り（`MAKOTO_TIME_SCALE`）
  #
  # ⚠ **rufus は `Time.now` を見ているので scale に自動追従する**（実測）。
  # ⚠⚠ **上限を決めるのは HTTP の実時間** — **投稿 1 本の実時間が見かけでは
  # scale 倍に伸びる**ので、⚠ **`/scheduler/tolerance`（30 秒）を食い尽くす倍率にしない。**
  #
  # 🔴 **実測は 0.7〜1.5 秒／投稿**（2026-09-23・#201 の 2.・**モロヘイヤ経由 ＝ 本番と同じ経路**）:
  #
  # | 出どころ | n | min | median | max |
  # | --- | --- | --- | --- | --- |
  # | 素の運用（`bydo`・scale 1・09-19〜09-23） | 20 | 0.755 | 0.913 | 1.144 |
  # | 8 回目のリハーサル（scale 10・見かけを `÷10`） | 163 | 0.108 | 0.710 | 1.141 |
  # | 経路の比較（scale 1・2026-09-23） | 6 | 1.061 | 1.275 | 1.472 |
  #
  # ⚠ **迂回（`X-Mulukhiya` 付き）なら 0.132〜0.219 秒**（同日・同じ `st2`）— 🔴 **差の約 1.1 秒は
  # モロヘイヤの取り回し**（#201 の 3.）。⚠⚠ **本番はモロヘイヤを通るので、上の表で見る。**
  #
  # 🔴 **ログの `seconds` は「見かけ」の側**（2026-09-23・#201）。⚠⚠ **`ginseng-core` の
  # `HTTP#log` は `Time.now` の差で秒を作り、`Timecop.thread_safe` の既定は `false`** なので、
  # ⚠ **投稿を投げる別スレッドにも scale が効く** — **実時間へ戻すには `÷ scale`。**
  # ⚠⚠ **この表の右列と同じ単位**なので、**突き合わせるときはログの値をそのまま読む。**
  # 🔴 **`PostingJob#warn_slow` の `seconds` は `CLOCK_MONOTONIC` ＝ 実時間で、別物。**
  #
  # | scale | 投稿 1 本 = 見かけ（median 〜 max） | |
  # | --- | --- | --- |
  # | 60 | 77〜88 秒 | 🔴 tolerance を食い尽くす。rufus の分解能も足りず枠あたりの exec 回数が変わる |
  # | 20 | 26〜29 秒 | ⚠ `MAX_SCALE`。**max がちょうど tolerance に届く**ので、ここが上限 |
  # | 10 | 13〜15 秒 | ✅ 8 時間が 48 分になる。**max でも tolerance の半分** |
  #
  # ⚠ **掛けているのは上の表のいちばん重い行**（**経路の比較の median 1.275 / max 1.472**）。
  # 🔴 **軽い回の数字で割ると上限が甘く出る**ので、**倍率を決めるときは重いほうを使う。**
  #
  # ## ⚠⚠ 早送りで取れないもの
  #
  # ⚠ **「早送りが通ったから大丈夫」と読まない。**実時間の経過そのものに依存する
  # もの（メモリの育ち方・接続の寿命・ログのローテート）と、⚠ **外部が実時間で
  # 持つ制限**（Mastodon のレート制限窓）と、⚠⚠ **「投稿が枠を跨ぐか」**
  # （#90 / #92 の領域）は実時間版でしか測れない。
  class TimeTravel
    include Package

    # 出発時刻。⚠ **これが無ければ何もしない。**
    START_KEY = 'MAKOTO_FAKE_TIME'.freeze

    # 見かけの時間を何倍で流すか。⚠ **省略時は等速。**
    SCALE_KEY = 'MAKOTO_TIME_SCALE'.freeze

    # 🔴 **日付を騙した状態で投稿してよい相手。**
    #
    # ⚠⚠ **allowlist にする（fail-closed）。**⚠ **「本番を弾く」ではなく
    # 「知っている相手にしか出さない」**にしておかないと、**投稿先が増えたときに
    # 素通りする。**⚠ **新しいステージングを建てたらここに足す。**
    ALLOWED_HOSTS = ['st2.precure.ml'].freeze

    # 早送りの上限。⚠⚠ **これを超えると投稿 1 本が `tolerance` を食い尽くし、
    # 「枠を跨ぐ」状態を人工的に作ってしまう**（→ このクラスの冒頭の表）。
    MAX_SCALE = 20

    # 出発時刻に要る「時:分」（#375）。⚠ **`T01:00` の形も通す。**
    TIME_OF_DAY = /(?:\A|[\sT])\d{1,2}:\d{2}/

    class << self
      # 発動を要求されているか。⚠ **要求と、実際に発動できるかは別。**
      def requested?
        return ENV[START_KEY].present?
      end

      # いま日付を騙しているか。
      def active?
        return @active.present?
      end

      # 発動する。⚠ **すべての入り口から呼ばれる**（→ `Makoto.rb`）ので、
      # ⚠⚠ **常駐と CLI が同じ時刻を見る。**
      #
      # 🔴 **通せない条件なら例外で落とす。**⚠⚠ **黙って無視しない** —
      # **偽の日付のまま本物のインスタンスへ投稿するのが最悪**なので、
      # **起動しないほうがまし。**
      def activate!
        return nil unless requested?
        # ⚠ テストは自前で時刻を作る。ここが効くと固定時刻の期待値が壊れる。
        return nil if Environment.test?
        verify!
        Timecop.travel(start_time)
        Timecop.scale(scale) unless scale == 1
        @active = describe
        logger.warn(time_travel: @active)
        return @active
      end

      # 人が読むための要約。⚠ **ハートビートのたびに出す**（→ `Scheduler`）。
      def describe
        return {
          start: start_time.iso8601,
          scale: scale,
          mastodon: mastodon_host,
        }
      end

      # 出発時刻。⚠ **読めなければ例外**（既定値に逃がすと、書き間違いが
      # 「いまの時刻で普通に動く」に化ける）。
      #
      # 🔴 **時刻を持たない値も弾く**（#375）。⚠⚠ **systemd の `Environment=` は空白で
      # 値を区切る**ので、**drop-in を引用符なしで書くと `2026-11-04` だけが残る** —
      # **`Time.parse` はそれを 11/4 00:00 として通し、別のリハーサルが静かに始まる**
      # （2026-09-19 に踏んだ）。⚠ **00:00 から始めたいときは `00:00:00` と明示する。**
      def start_time
        return @start_time ||= begin
          value = ENV[START_KEY].to_s
          unless value.match?(TIME_OF_DAY)
            hint = 'quote the whole value in the drop-in, e.g. "2026-11-04 11:58:00 +0900"'
            raise Ginseng::ConfigError,
              "time travel: #{START_KEY} '#{value}' has no time of day (#{hint})"
          end
          Time.parse(value)
        end
      rescue ArgumentError
        raise Ginseng::ConfigError,
          "time travel: bad #{START_KEY} '#{ENV.fetch(START_KEY, nil)}'"
      end

      # 早送りの倍率。⚠ **省略時は 1（等速）。**
      def scale
        return @scale ||= begin
          value = ENV[SCALE_KEY].presence&.to_i || 1
          unless value.positive? && value <= MAX_SCALE
            raise Ginseng::ConfigError,
              "time travel: bad #{SCALE_KEY} '#{ENV.fetch(SCALE_KEY, nil)}' (1..#{MAX_SCALE})"
          end
          value
        end
      end

      def mastodon_host
        return Ginseng::URI.parse(config['/mastodon/url']).host.to_s
      rescue
        return ''
      end

      # ⚠⚠ **通してよいかを確かめる。**⚠ **投稿先を主たる判定にする** —
      # 🔴 **`environment` は表示以外に何も変えない値**なので、それだけに頼ると
      # **間違って `development` のまま建てた箱で素通りする。**
      def verify!
        if Environment.production?
          raise Ginseng::ConfigError, 'time travel: refused (environment is production)'
        end
        return true if ALLOWED_HOSTS.include?(mastodon_host)
        raise Ginseng::ConfigError,
          "time travel: refused (mastodon host '#{mastodon_host}' is not allowed)"
      end

      # ⚠ テストが後始末に使う。
      def reset!
        @active = nil
        @start_time = nil
        @scale = nil
        Timecop.return
        return nil
      end
    end
  end
end
