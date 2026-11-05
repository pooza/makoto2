module Makoto
  # ライブのゲストコーナーに置く曲を引く（#13 / #65 / #88）。
  #
  # ⚠⚠ **本編とは別軸。**`Setlist` の本編は**発売日で整列するだけ**（抽選ではない）
  # だが、⚠ **カバーは母集合を絞ってから引く**（→ docs/CLAUDE.md「ライブの並びは
  # 抽選ではなく整列」）。**同じクラスに置くと、この 2 つが混ざって読める。**
  #
  # ## 母集合の作り方
  #
  # ⚠⚠ **「`live` に無い vocal ＝ 他の歌手の持ち歌」**を候補にし、そこから
  # **プリキュア歌手の持ち歌だけ**を残す（cure-api の `/singers`）。
  # ⚠ **絞らないとカラオケレーベル（歌っちゃ王）・オルゴール盤・ドラマトラックが
  # ゲストコーナーに並ぶ。**⚠⚠ **曲データの `kind` は当てにならない**（歌っちゃ王
  # 125 曲のうち 83 曲が `vocal`）ので、**名義の側で落とす。**
  #
  # ## ⚠ 引けない・足りないときに黙らない（#88）
  #
  # **「静かに出ない」がいちばん危ない**（⚠ **抽選の引き次第なので、たまたま出ない日
  # には気付けない**）。⚠⚠ **4 つの経路すべてに警告を置く。**
  #
  # | 状況 | 警告 |
  # | --- | --- |
  # | cure-api が引けない | `cure-api is unavailable` |
  # | ⚠ **200 だが 1 件も一致しない** | `no track matched the singer list`（#80 の黄 3） |
  # | ⚠ 要求数に満たない | `fewer covers than requested` |
  #
  # ⚠ **写しで代わったこと**は `CureApiService` の側が言う（そちらが気付ける唯一の場所）。
  class CoverSelector
    include Package

    PREFIX = '/live/setlist'.freeze

    # @param date [Date] ⚠ **抽選の種。****同じ日付なら毎回同じカバーを引く**
    #   （枠ごとに引き直すと再起動で並びが変わる）。⚠ 年で種が変わるので来年は別の曲
    def initialize(date:, repository: nil, cure_api: nil)
      @date = date
      @repository = repository || TrackRepository.new
      @cure_api = cure_api || CureApiService.new
    end

    # ゲストコーナーごとの曲数（前半・後半）。⚠ **整数なら両方同じ。**
    #
    # 🔴 **前半・後半で変えられる**（#287）— ⚠ **本編から朗読劇を外して空いた枠を、後半のコーナーで埋めた。**
    def sizes
      value = config["#{PREFIX}/cover_size"]
      return Array.new(2, value.to_i) unless value.is_a?(Array)
      return value.first(2).map(&:to_i)
    end

    def exec
      total = sizes.sum
      return [] unless total.positive?
      unless @cure_api.available?
        warn('cure-api is unavailable')
        return []
      end
      pool = pool_of_singers
      if pool.empty?
        warn('no track matched the singer list')
        return []
      end
      picked = sample(pool, total)
      if picked.size < total
        warn('fewer covers than requested', requested: total, picked: picked.size)
      end
      return picked
    end

    private

    # 🔴 **本人の曲を混ぜない**（#177 / #183）。⚠⚠ **`live` フラグは収集の産物**なので、
    # **`キュア・カルテット` 名義の曲は「他の歌手の持ち歌」に見える** — ⚠ **当たると
    # 本人の曲を「（お借りした歌）」として出すことになる**（実測で 4 曲）。
    # ⚠⚠ **判定は `OwnCredit`**（本編・表示と同じ規則 → `Setlist#songs`）。
    #
    # 🔴 **外すのは「鍵」で、代表を選ぶ前**（#183・2026-09-07）。⚠⚠ **かつては
    # `live` の鍵だけを外し、選ばれた代表 1 行を `own?` に掛けていた** — ⚠ **同じ
    # `dedupe_key` に本人名義の行と他人名義の行が混ざると、本編には本人の曲として
    # 入り、カバー母集合には他人名義の代表が残る**（🔴 **同じ曲が本編とカバーの
    # 両方に出て、片方が「（お借りした歌）」になる** ＝ **#177 が塞いだはずの形**）。
    #
    # ⚠ `dedupe_key` が NULL の行を部分集合に混ぜない（→ `OwnCredit.keys`）。
    def pool_of_singers
      pool = distinct(@repository.by_kind('vocal'))
        .exclude(dedupe_key: OwnCredit.keys(@repository)).order(:id).all
      return pool.select {|track| @cure_api.singer?(track[:artist_name])}
    end

    # ⚠ **代表を選ぶ前に url で絞る**（→ `Setlist#distinct` と同じ理由）。
    def distinct(records)
      return @repository.distinct(@repository.linkable(records))
    end

    # 🔴 **曲ごとにスコアを出し、小さい順に取る**（#309）。⚠⚠ **母集合を並べて
    # `Random` で引く形は、1 曲増えるだけで並びの位置がずれ、ほぼ全部が引き直しに
    # なっていた**（2026-09-11 の実測で 11/4 のカバー 8 曲のうち 6 曲）。
    # **スコアは曲ごとに独立**なので、⚠ **新しい曲が既存のカバーを押し出すのは、
    # その曲のスコアが上位に入るときだけ。**
    #
    # ⚠ **重み付きの非復元抽出は Efraimidis–Spirakis の形**（`-ln(U) / 重み` の小さい順）。
    # 重みがすべて 1 なら一様抽選と同じ分布になる。
    def sample(pool, total)
      return pool.sort_by {|track| [score_of(track), key_of(track)]}.first(total)
    end

    def score_of(track)
      return -Math.log(uniform_of(track)) / weight_of(track)
    end

    # 🔴 **日付と曲の鍵から決まる (0, 1) の値。**⚠⚠ **`Random` は使わない**
    # （→ `Rotation.shuffle` と同じ理由 — **Ruby の実装・版に依存しうる**）。
    # ⚠ **0 を出さない**（`-ln(0)` は無限大）ので、53 ビットに 0.5 を足して割る。
    def uniform_of(track)
      digest = Digest::SHA256.hexdigest("#{@date.strftime('%Y%m%d')}-#{key_of(track)}")
      return ((digest[0, 14].to_i(16) >> 3) + 0.5).fdiv(1 << 53)
    end

    # 🔴 **鍵は `dedupe_key`**（`id` は DB ごとの採番なので、`bydo` と `rubicon` で
    # 同じ曲が別の番号になる → `Rotation.key_of` と同じ理由）。⚠ **母集合は
    # `distinct` を通した代表なので、鍵は曲ごとに 1 つ。**
    def key_of(track)
      return track[:dedupe_key] if track[:dedupe_key]
      # ⚠ **鍵の無い行**は、その箱の中では決定的だが箱をまたいでは揃わない。
      return "id:#{track[:id]}"
    end

    def warn(message, **rest)
      return logger.warn({setlist: 'covers', message: message, date: @date.to_s}.merge(rest))
    end

    # ⚠⚠ **単独名義を優先して引く**（#65）。**MAKOTO は 1 人で歌う**ので、
    # 本来複数の歌手で歌う曲を 1 人でカバーするのは不自然。
    #
    # ⚠ **排除ではなく寄せる。**ありえなくはないので、重みで確率を変えるだけにする。
    # ⚠ **1 以下なら一様抽選**（＝この機能を切る。⚠ **設定を消しても同じ**）。
    # ⚠⚠ **`optional_config` で読む**（素の `config[]` は消すと例外 → #77）。
    def solo_weight
      return optional_config("#{PREFIX}/cover_solo_weight").to_i
    end

    def weight_of(track)
      return 1 if solo_weight <= 1
      return CureApiService.credit_count(track[:artist_name]) == 1 ? solo_weight : 1
    end
  end
end
