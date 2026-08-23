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

    # ゲストコーナー 1 つあたりの曲数。⚠ **前半・後半に 1 つずつ置くので 2 倍が総数。**
    def size
      return config["#{PREFIX}/cover_size"].to_i
    end

    def exec
      total = size * 2
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

    # ⚠ `dedupe_key` が NULL の行を部分集合に混ぜない。**`NOT IN` は NULL が 1 つでも
    # 混ざると 1 行も返さない**ので、静かに「カバー無し」になる。
    # 🔴 **本人がメンバーのユニット名義の曲を混ぜない**（#177）。⚠⚠ **`live` フラグは
    # 収集の産物なので、`キュア・カルテット` 名義の曲は「他の歌手の持ち歌」に見える** —
    # ⚠ **当たると本人の曲を「（お借りした歌）」として出すことになる**（実測で 4 曲）。
    # ⚠⚠ **判定は `OwnCredit`**（本編・表示と同じ規則 → `Setlist#own_records`）。
    def pool_of_singers
      live_keys = @repository.live.exclude(dedupe_key: nil).select(:dedupe_key)
      pool = distinct(@repository.by_kind('vocal')).exclude(dedupe_key: live_keys).order(:id).all
      pool = pool.reject {|track| OwnCredit.own?(track[:artist_name])}
      return pool.select {|track| @cure_api.singer?(track[:artist_name])}
    end

    # ⚠ **代表を選ぶ前に url で絞る**（→ `Setlist#distinct` と同じ理由）。
    def distinct(records)
      return @repository.distinct(@repository.linkable(records))
    end

    def sample(pool, total)
      random = Random.new(@date.strftime('%Y%m%d').to_i)
      return pool.sample(total, random: random) if solo_weight <= 1
      return weighted_sample(pool, total, random)
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
      return CureApiService.credit_count(track[:artist_name]) == 1 ? solo_weight : 1
    end

    # 重み付きの非復元抽出。⚠⚠ **同じ日付なら毎回同じ並びになること**を壊さない
    # （種は日付から作る。壊すと再起動で曲順が変わる）。
    def weighted_sample(pool, total, random)
      remaining = pool.dup
      results = []
      while results.size < total && remaining.any?
        results.push(remaining.delete_at(pick_index(remaining, random)))
      end
      return results
    end

    def pick_index(remaining, random)
      weights = remaining.map {|track| weight_of(track)}
      point = random.rand(weights.sum.to_f)
      weights.each_with_index do |weight, index|
        point -= weight
        return index if point.negative?
      end
      return remaining.size - 1
    end
  end
end
