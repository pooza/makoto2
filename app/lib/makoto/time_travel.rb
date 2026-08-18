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
  # scale 倍に伸びる**（実測 0.13〜0.91 秒／投稿）ので、⚠ **`/scheduler/tolerance`
  # （30 秒）を食い尽くす倍率にしない。**
  #
  # | scale | 投稿 1 本 = 見かけ | |
  # | --- | --- | --- |
  # | 60 | 8〜55 秒 | 🔴 tolerance を食い尽くす。rufus の分解能も足りず枠あたりの exec 回数が変わる |
  # | 10 | 1.3〜9 秒 | ✅ 8 時間が 48 分になる |
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
      def start_time
        return @start_time ||= Time.parse(ENV[START_KEY].to_s)
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
