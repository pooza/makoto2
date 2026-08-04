module Makoto
  # `kind` で重み付けした曲の抽選。日常の曲紹介（#16）が使う。
  #
  # ⚠ **普段用 4,305 行のうち BGM が 53%。**一様に引くと曲紹介がサントラだらけになる
  # （→ [track-corpus.md](../../../docs/track-corpus.md)）。
  #
  # ⚠⚠ **重みは「その kind が選ばれる確率の比」。**先に kind を重みで選び、その中から
  # 一様に 1 曲を引く。**曲数の偏りに影響されない**ので、`vocal: 10` / `bgm: 2` と
  # 書けば「vocal は bgm の 5 倍出やすい」がそのまま成り立つ。
  #
  # ⚠ **ライブ（#13）はこれを使わない。**ライブはセットリストとして組む＝整列であって
  # 抽選ではない（→ [birthday-live.md](../../../docs/birthday-live.md)）。
  #
  # ⚠ 投稿履歴による重複回避は #41。ここでは扱わない。
  class TrackLottery
    include Package

    WEIGHT_PREFIX = '/track/weight'.freeze

    attr_reader :random

    # ⚠ `random` を差し替えられるようにしてあるのはテストのため。分布を確認する
    # テストは乱数に依存するので、シードを固定できないと落ちたり通ったりする。
    def initialize(repository = nil, random: Random.new)
      @repository = repository || TrackRepository.new
      @random = random
    end

    # 抽選の母集合。
    #
    # ⚠ **`distinct` で名義違い・盤違いの同一曲を 1 行に寄せる**（寄せないと同じ曲が
    # 何度も当たる）。⚠ **`linkable` で url の無い行を落とす** — 曲紹介はリンク付きで
    # 曲そのものを出すので、url が無い行は紹介の形にならない。
    #
    # ⚠⚠ **順序が効く。`linkable` してから代表を選ぶ。**逆にすると、代表になった行
    # だけ url が無いときに**同じ曲の url がある行ごと落ちる**（`url` は NULL 可）。
    # 「特定の曲だけ静かに出ない」形になり、無人で回る曲紹介では誰も気付けない。
    def candidates
      return @repository.distinct(@repository.linkable)
    end

    # 1 曲引く。⚠ **母集合が空なら nil。設定の誤りは例外。**
    def draw(records = nil)
      records ||= candidates
      counts = @repository.count_by_kind(records)
      # 母集合がそもそも空（例: 絞り込んだ結果 0 件）。これは設定の誤りではない。
      return nil if counts.empty?
      kind = pick_kind(counts)
      # ⚠⚠ **母集合はあるのに引けない ＝ 実効的な重みがゼロ。**正の重みが付いた kind が
      # 1 曲も居ない状態で、`weights` の「全部 0 は誤り」検査をすり抜ける。黙って nil を
      # 返し続けると曲紹介が無言で止まるので、ここで落とす。
      unless kind
        raise Ginseng::ConfigError,
          "track: no positive weight for available kinds (#{counts.keys.sort.join(', ')})"
      end
      return pick_track(records.where(kind: kind))
    end

    # 設定された重み。
    #
    # ⚠ `Ginseng::Config` は葉のパスしか引けない（`/track/weight` そのものは
    # 取れない）ので、`keys` で子を列挙してから 1 つずつ読む。
    #
    # ⚠⚠ **全部 0 は設定の誤り。**黙って「何も引けない」状態にすると、曲紹介が
    # 無言で止まる（無人で動くボットでは誰も気付けない）。
    def weights
      kinds = config.keys(WEIGHT_PREFIX)
      raise Ginseng::ConfigError, "track: #{WEIGHT_PREFIX} is missing" if kinds.empty?
      values = kinds.to_h {|kind| [kind.to_s, config["#{WEIGHT_PREFIX}/#{kind}"].to_i]}
      raise Ginseng::ConfigError, 'track: negative weight' if values.values.any?(&:negative?)
      raise Ginseng::ConfigError, 'track: all weights are zero' unless values.values.sum.positive?
      return values
    end

    private

    # 実際に曲がある kind だけを対象に、重みで 1 つ選ぶ。
    #
    # ⚠ **曲が 0 件の kind を選んでから引き直す作りにしない。**母集合の絞り込み
    # （`linkable` など）で特定の kind が空になることがあり、引き直しは最悪ループする。
    def pick_kind(counts)
      pool = weights.select {|kind, weight| weight.positive? && counts[kind].to_i.positive?}
      warn_unweighted(counts)
      return nil if pool.empty?
      target = @random.rand(pool.values.sum)
      pool.each do |kind, weight|
        return kind if target < weight
        target -= weight
      end
      return nil
    end

    # ⚠ **重みが定義されていない kind は永久に出ない。**設定漏れが「静かに出ない」に
    # なるのを避けるため、母集合に居るのに重みが無いものはログに出す。
    def warn_unweighted(counts)
      missing = counts.keys.map(&:to_s) - weights.keys
      return if missing.empty?
      logger.warn(track: 'lottery', message: 'kind has no weight', kind: missing)
    end

    def pick_track(records)
      ids = records.select_map(:id)
      return nil if ids.empty?
      return records.first(id: ids[@random.rand(ids.size)])
    end
  end
end
