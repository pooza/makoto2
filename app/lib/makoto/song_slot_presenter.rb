module Makoto
  # `makoto song slot` の表示（枠・黙る日・前置きの本数・語りのトラック・履歴・抽選の母集合）。
  #
  # ⚠ **`SongCommand` から分けた**（#314）。🔴 **束ごとの行の場合分けを足したら、クラスの長さの上限を
  # 超えた。**⚠ 出力は `puts` のまま（コマンドの側と同じ）。
  class SongSlotPresenter
    include Package

    def initialize(song, repository)
      @song = song
      @repository = repository
    end

    def print
      job = song.job
      puts "#{job.name}: #{job.timetable}"
      puts "1 日 #{job.timetable.size(today)} 本（#{slot_times(job)}）"
      puts "実況の窓: #{CommentaryWindow.new}"
      dump_quiet_days
      dump_prefixes
      dump_spoken
      dump_history
      dump_pool
      return nil
    end

    private

    attr_reader :song, :repository

    # ⚠ **枠の時刻を並べる。**⚠⚠ **文字列補間の中に複数行の `do…end` を書かない**
    # （`app/lib` ＋ `bin/makoto` でここだけがその形だった ＝ #285）。
    def slot_times(job)
      return job.timetable.times(today).map {|time| time.strftime('%H:%M')}.join(' / ')
    end

    # 🔴 **ライブが持つ日は黙る**（Codex の P1）。⚠⚠ **設定を消すと黙らなくなる**ので、
    # ⚠ **「いま何日が黙る日か」がここに出る。**
    def dump_quiet_days
      types = song.quiet_types
      if types.empty?
        puts '黙る日: 無し（⚠ ライブの日も日常の曲を出します）'
        return nil
      end
      days = song.selector.anniversary_types.select {|_, names| names.intersect?(types)}.keys
      puts "黙る日: #{days.sort.join(' / ')}（#{types.join(', ')}）"
      return nil
    end

    # 🔴 **一周の長さ ＝ 前置きの本数 ÷ 1 日の本数**（#223 の規則を通す）。
    # ⚠⚠ **同じ前置きが戻るまでの間隔は、その半分を下回らない。**
    #
    # 🔴 **`kind` ごとに候補の束が違う**（#293）ので、**束ごとに 1 行ずつ出す。**
    # ⚠ **束は種類別だけ**（共通は混ぜない → `Song#kind_selectors`）。
    def dump_prefixes
      slots = song.timetable.size(today)
      common = song.selector.list(today).size
      groups = prefix_groups
      # 🔴 **種類別が 1 本でもあれば、共通も毎枠は引かれない**（→ `SongSource#pool`）。
      exact = groups.keys.all? {|name| type_size(name).zero?}
      return puts('前置きの原稿: 0 本（⚠ 曲だけを出します）') if common.zero? && exact
      note = common.zero? ? '⚠ 種類別の無い kind は曲だけ' : cycle_note(common, slots, exact:)
      puts "前置きの原稿: 共通 #{common} 本（#{song.type}・#{note}）"
      groups.each {|name, kinds| puts group_line(name, kinds, slots, common)}
      return nil
    end

    # `{type => [kind, ...]}`。⚠ **複数の `kind` が同じ type を指す**ので、束ねて 1 行にする。
    def prefix_groups
      return song.kind_types.group_by(&:last).transform_values {|pairs| pairs.map(&:first)}
    end

    # ⚠ **束 1 つぶん。**🔴 **種類別が 0 本なら、そう書く**（**共通だけで回っている**）。
    #
    # ⚠ **種類別の束は「その種類の曲が出た枠の、さらに一部」でしか引かれない**
    # （→ `SongSource#pool`）ので、**一周の日数は出せない。下限だけを出す**（Codex の P2）。
    #
    # 🔴 **共通が 0 本の場合を分ける**（#314）。⚠⚠ **片方が 0 本なら、もう片方を毎枠引く**
    # （→ `SongSource#pool`）ので、**種類別が 0 本なら曲だけ・あれば毎枠その束**になる。
    def group_line(name, kinds, slots, common)
      own = type_size(name)
      label = "  #{kinds.join(' / ')}: #{name} #{own} 本"
      return "#{label}（⚠ #{common.zero? ? '曲だけ' : '共通だけ'}）" if own.zero?
      cycle = cycle_note(own, slots, exact: false)
      return "#{label}（毎枠この束・#{cycle}）" if common.zero?
      return "#{label}（共通と本数の比で引き分け・#{cycle}）"
    end

    # 🔴 **語りのトラック**（#298 → `SpokenTracks`）。⚠ **共通の前置きだけが付く。**
    #
    # ⚠⚠ **母集合に当たらない名前も出す**（書き間違い・配信終了）— 🔴 **当たらない行は
    # 「表に書いたのに効いていない」**ので、**歌向けの前置きが付いていても気づけない。**
    def dump_spoken
      spoken = song.spoken_tracks
      return puts('語りのトラック: 無し') if spoken.empty?
      unused = spoken.unused(song.lottery.candidates.select_map(:dedupe_key).to_set)
      line = "語りのトラック: #{spoken.names.size} 本（共通の前置きだけ）"
      line = "#{line} 🔴 母集合に当たらない: #{unused.join(' / ')}" unless unused.empty?
      puts line
    rescue => e
      # ⚠ **`ValidateError` だけを受けない**（#314）— **実行時の倒し方（`SongSource#spoken?`）と揃える**（#312）。
      puts "語りのトラック: 🔴 表を読めません（⚠ 全部の曲を共通だけにします）: #{error_message(e)}"
    end

    # その type だけの本数。
    def type_size(name)
      return song.selector_of([name]).list(today).size
    end

    # 🔴 **「同じ前置きが戻るのは最短 n/2 枠」は、束が毎枠引かれなくても成り立つ**
    # （**通し番号の距離の話**なので、**引かれない枠が挟まるほど間隔は延びるだけ**）。
    #
    # ⚠⚠ **一周の日数は、束が毎枠引かれるときにしか言えない**（Codex の P2）。
    # ⚠ **`exact: false` なら下限だけを出す**（**一周は曲の種類の出方で延びる**）。
    def cycle_note(size, slots, exact: true)
      cycle = ((size.to_f / slots) * 10).round / 10.0
      return "一周 #{cycle} 日・同じ前置きが戻るのは最短 #{cycle / 2} 日" if exact
      return "同じ前置きが戻るのは最短 #{cycle / 2} 日・⚠ 一周は曲の種類の出方で延びる"
    end

    # 🔴 **最近出した曲を避けているか**（#41）。⚠⚠ **設定を消せば止まる**ので、
    # ⚠ **「いま何本ぶん避けているか」がここに出る。**
    #
    # ⚠ **記録が窓に満たないうちは、その本数しか避けていない**（🔴 **入れたその日から
    # 効くわけではない**）。
    def dump_history
      history = song.history
      unless history.enabled?
        puts '最近出した曲を避ける: 無し（⚠ 同じ曲が続けて出ることがあります）'
        return nil
      end
      last = history.last
      when_ = last ? "最後は #{last[:posted_at]}" : '⚠ まだ 1 本も出していません'
      puts "最近出した曲を避ける: #{history}（記録 #{history.count} 本・#{when_}）"
      return nil
    end

    # ⚠ **抽選の母集合。**🔴 **重みは「その kind が選ばれる確率の比」**であって
    # 曲数の割合ではない（→ docs/track-corpus.md）。
    def dump_pool
      counts = repository.count_by_kind(song.lottery.candidates)
      weights = song.lottery.weights
      puts "抽選の母集合: #{counts.values.sum} 曲"
      weights.sort_by {|_, weight| -weight}
        .each {|kind, weight| puts pool_line(kind, weight, counts, weights)}
      return nil
    end

    # ⚠⚠ **出る割合は「重みの合計」に対する比**で、⚠ **曲が 1 曲も無い kind は
    # 分母にも入らない**（→ `TrackLottery#pick_kind`）。
    #
    # 🔴 **分母から外した kind は 0% と出す**（Codex の P2）。⚠⚠ **重みだけで割ると、
    # 1 曲も無い kind が「20% 出る」と表示される** — ⚠ **この画面はまさに
    # 「母集合と設定の食い違い」を見るためのもの**なので、**そこで嘘をつかない。**
    def pool_line(kind, weight, counts, weights)
      count = counts[kind].to_i
      total = weights.select {|name, value| value.positive? && counts[name].to_i.positive?}
        .values.sum
      share = count.positive? && total.positive? ? (weight * 100.0 / total) : 0.0
      marker = song.collection_kinds.include?(kind) ? ' ⚠ アルバム名を出す' : ''
      # ⚠ **重みが付いているのに 1 曲も無い**のは設定漏れの合図（→ `TrackLottery#warn_unweighted`
      # の裏返し）。🔴 **0% とだけ書くと「重みが 0 なのか曲が無いのか」が読めない。**
      marker = "#{marker} 🔴 曲が 1 曲も無い" if count.zero? && weight.positive?
      return "  #{kind.to_s.ljust(13)} 重み #{weight}  #{count} 曲  #{share.round(1)}%#{marker}"
    end

    # ⚠⚠ **ホストの TZ ではなく `/scheduler/timezone` で「今日」を出す**（→ `SongCommand#today`）。
    def today
      return song.selector.date_of(Time.now)
    end
  end
end
