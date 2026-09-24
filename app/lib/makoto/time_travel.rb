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
  # 🔴 **実測は 0.7〜1.6 秒／投稿**（2026-09-23・#201 の 2.・**モロヘイヤ経由 ＝ 本番と同じ経路**）:
  #
  # | 出どころ | n | min | median | max |
  # | --- | --- | --- | --- | --- |
  # | 素の運用（`bydo`・scale 1・09-19〜09-23） | 20 | 0.755 | 0.913 | 1.144 |
  # | 8 回目のリハーサル（scale 10・見かけを `÷10`） | 162 | 0.595 | 0.710 | 1.141 |
  # | 7 回目のリハーサル（同上） | 162 | 0.608 | 0.709 | 🔴 **1.517** |
  # | 5 回目のリハーサル（同上） | 162 | 0.595 | 0.677 | 1.497 |
  # | 経路の比較（scale 1・2026-09-23） | 6 | 1.061 | 1.275 | 1.472 |
  #
  # 🔴 **max は毎回「1 本目」**（接続の立ち上げぶん）。⚠⚠ **たまたまの外れ値ではなく、
  # どの回にも 1 本ある**ので、**上限を決めるときは外さない。**
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
  # | 60 | 77〜91 秒 | 🔴 tolerance を食い尽くす。rufus の分解能も足りず枠あたりの exec 回数が変わる |
  # | 20 | 26〜🔴 **30.3** 秒 | 🔴 **tolerance（30 秒）を超える** — ⚠ **2026-09-24 に降ろした**（#404） |
  # | 15 | 19〜**22.8** 秒 | ⚠ **いまの `MAX_SCALE`。**max でも tolerance の 76% |
  # | 10 | 13〜15 秒 | ✅ 8 時間が 48 分になる。**max でも tolerance の半分**。⚠ **運用値** |
  #
  # ⚠ **掛けているのは、median は上の表のいちばん重い行（1.275）・max は全部の中の最大（1.517）。**
  # 🔴 **軽い回の数字で割ると上限が甘く出る**ので、**倍率を決めるときは重いほうを使う。**
  #
  # ✅ **`MAX_SCALE` は 2026-09-24 に 20 → 15 へ下げた**（#404・オーナー判断）。
  # 🔴 **20 は実測に追い越されていた** — ⚠⚠ **7 回目のリハーサルの 1 本目が見かけ 15.171 秒
  # ＝ 実時間 1.517 秒**で、**scale 20 なら見かけ 30.3 秒** ＝ ⚠ **`/scheduler/tolerance` の
  # 30 秒をわずかに超える。**⚠ **実害は出ていなかった**（**使っていたのは `scale 10`**）が、
  # 🔴 **「上限として置いてある値なら安全」が成り立たない状態だった。**
  # ⚠⚠ **引き直し方は定数の隣に置いた**（→ `MAX_SCALE`）— **次に実測が動いたときに
  # 根拠を探さずに引き直せるように。**
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
    #
    # 🔴 **引き直し方**（2026-09-24・#404）— **`記録の中の最大（実時間） × scale ≤ tolerance`**:
    #
    # | | 値 | 出どころ |
    # | --- | --- | --- |
    # | 記録の中の最大（実時間） | **1.517** 秒 | 7 回目のリハーサルの 1 本目（→ 冒頭の表） |
    # | `/scheduler/tolerance` | **30** 秒 | `config/application.yaml` |
    # | 理論上の上限（`30 ÷ 1.517`） | **19** | 余裕ゼロ |
    # | 🔴 **ここで採る値** | **15** | 見かけ **22.8** 秒 ＝ tolerance の **76%**（余裕 24%） |
    #
    # ⚠⚠ **max を落とさない。**🔴 **最大は毎回「1 本目」**（接続の立ち上げぶん）で、
    # ⚠ **どの回にも必ず 1 本ある**ので、**外れ値として外すと上限が甘く出る。**
    MAX_SCALE = 15

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
      #
      # 🔴 **上限で弾くときは理由も返す**（#404）。⚠⚠ **範囲だけを返すと、drop-in を
      # 書く人には「足りないから上げればよい数字」に見える** — ⚠ **上限は実測から
      # 引いた値**なので、**上げるなら実測ごと引き直すしかない**（→ `MAX_SCALE`）。
      def scale
        return @scale ||= begin
          value = ENV[SCALE_KEY].presence&.to_i || 1
          unless value.positive? && value <= MAX_SCALE
            raw = ENV.fetch(SCALE_KEY, nil)
            hint = 'the ceiling keeps one post inside /scheduler/tolerance'
            raise Ginseng::ConfigError,
              "time travel: bad #{SCALE_KEY} '#{raw}' (1..#{MAX_SCALE}: #{hint})"
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
