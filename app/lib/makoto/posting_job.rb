module Makoto
  # 枠（`Timetable`）に載せる投稿 1 本ぶん。ライブ（#13）も朝挨拶（#17）も
  # 曲紹介（#16）も、**何を投稿するか（`source`）だけ差し替えて**ここに載る。
  #
  # ```
  # いつ投げるか → Timetable
  # 何を投げるか → source（call(slot) が本文を返すもの）
  # どう投げるか → PostingJob（ここ）
  # ```
  #
  # ⚠⚠ **進行位置を状態として持たない。**「次はどの枠か」を覚えず、**渡された時刻が
  # 枠の頭に入っているか**だけを見る。⚠ **落ちて戻ってきても位置がずれない**（→ #10 の
  # 「再起動後の状態復帰」）。
  #
  # 🔴 **ただし「いま処理した枠」だけは覚える**（#109・2026-08-19）。⚠ **これは進行
  # 位置ではない** — **プロセス内だけの、同じ枠を二度叩かないための記憶**で、
  # ⚠⚠ **消えても（＝再起動しても）位置は時刻から計算し直される。**
  #
  # ⚠ **無いと 1 枠が 3 回 `exec` される。**`tolerance`（30 秒）が `tick`（10 秒）の
  # 3 倍なので、**枠の頭 +0 / +10 / +20 の tick がすべて「いま枠の頭だ」と答える。**
  # ⚠⚠ **`tolerance` は「枠を取りこぼさない」ためのものであって、「3 回投げる」ため
  # のものではない。**🔴 **実測（2026-08-18・`bydo` → `st2`）では 6 枠すべてが
  # 1 回目 200・2 回目と 3 回目が 500** で、⚠⚠ **本番の 160 枠なら 8 時間で 960 回の
  # 失敗 POST になる。**⚠ **500 が止まれば、今度は全投稿が 3 通ずつ出る。**
  #
  # ⚠⚠ **失敗しても例外を外に出さない。**`source` が落ちても投稿が失敗しても、
  # ログに残して次の枠へ進む。**落とした分は後ろに詰めない**（→ docs/CLAUDE.md
  # 「投稿の欠落は詰めない」）。⚠ 例外を上げると常駐そのものが止まり、**残り 8 時間の
  # 枠を全部落とす**ことになる。
  #
  # ⚠ **冪等キーは枠から作る。**⚠⚠ **同じ枠なら本文が変わっても同じキー**（抽選を
  # やり直してもキーが動かない）。🔴 **ただし「Mastodon 側が畳む」を当てにしない**
  # （#109 → `idempotency_key`）。⚠ **プロセス内の重なりは `claim` が塞ぐ**ので、
  # **キーに残っている仕事は再起動をまたぐ重なりだけ。**
  class PostingJob
    include Package

    attr_reader :name, :timetable, :tolerance, :visibility

    # 直近いくつの枠を覚えておくか（#126）。
    #
    # ⚠ **決めるのは「停滞しうる時間 ÷ 枠の間隔」**であって、拾う幅ではない。
    # ⚠⚠ **1 回の tick は投稿の再送で 90 秒以上かかりうる**うえ、⚠ **いちばん短い枠は
    # 予告・告知の 1 分**なので、**数枠ぶんの余裕を持たせる。**
    # 🔴 **8 なら、1 分の枠でも 8 分ぶんの遅れに耐える**（ライブの 3 分枠なら 24 分）。
    CLAIM_MEMORY = 8

    # @param name [String] ログと冪等キーに使う名前。⚠ 投稿の種類ごとに一意にする
    # @param timetable [Timetable] 枠
    # @param source [#call] 枠の頭の時刻を受け取り、投稿の本文を返すもの
    # @param tolerance [String, Numeric] 枠の頭を拾う幅。既定は `/scheduler/tolerance`
    #
    # ⚠⚠ **既定を `/scheduler/tick` にしない**（#90 / #80 の黄 8）。⚠ **同値だと
    # 拾えるのは tick が `[枠の頭, 枠の頭+tick)` に落ちたときだけで、余裕が構造的に
    # ゼロ**になる。⚠⚠ **ライブの枠間隔 180 秒は tick の 10 秒の整数倍なので、
    # 位相ずれは 160 枠すべてに同じように効く**（1 枠だけの事故にならない）。
    def initialize(name:, timetable:, source:, tolerance: nil, visibility: nil)
      @name = name.to_s
      @timetable = timetable
      @source = source
      @tolerance = parse_tolerance(tolerance || config['/scheduler/tolerance'])
      @visibility = visibility
      # 🔴 **同じ枠を二度叩かないための記憶**（#109）。⚠ **`tick` は重なりうる**
      # （rufus の `every` は前の回が終わるのを待たず、⚠⚠ **1 回の tick は投稿の
      # 再送で 90 秒以上かかりうる**）ので、**見て書くまでを不可分にする。**
      # ⚠ **直近いくつかを覚える**（#126 → `claim`）。
      @claimed = []
      @claim_mutex = Mutex.new
      validate
    end

    # 枠の頭か。⚠ **tick はぴったりの時刻には来ない**ので、`tolerance` の幅だけ
    # 遅れて呼ばれても拾う。
    def due?(time = nil)
      return !due_slot(time).nil?
    end

    # 枠の頭なら投稿する。⚠ 枠の外・枠の途中・本文が空なら何もしない。
    #
    # ⚠⚠ **戻り値は 3 つの結末を区別しない**（投稿しなかったものはどれも nil）。
    # **区別は `Heartbeat` に記録する側で付ける**（→ #78）。呼ぶ側は
    # `Scheduler#tick` だけで、そちらは結末を使わない。
    def exec(time = nil)
      slot = claim(due_slot(time))
      return nil unless slot
      text = create_text(slot)
      # ⚠ **nil は `source` が落ちたことを指す**（`create_text` が記録済み）。
      # ⚠⚠ **空文字と混ぜない** — 混ぜると #77 の「設定を消すと枠の中で例外が上がる」
      # 形が「原稿の無い日」に化けて、**160 枠が沈黙しても健全に見える。**
      return nil if text.nil?
      if text.blank?
        # ⚠ 本文が無いのは「投稿しない」であって異常ではない（原稿が無い日など）。
        # ⚠⚠ **成功にも失敗にも数えない。**→ `Heartbeat` 冒頭の表。
        #
        # ⚠ **`debug` なのは、これが平常日に 171 行出るから**（#80 の黄 9）。
        # ⚠⚠ **ライブの 4 枠は毎日空回りする設計**なので、これを `info` に置くと
        # **11/4 に壊れて何も出なかった日のログが、平常日と 1 文字も変わらない。**
        # ⚠ **「出るべき日に出なかった」を言えるのは中身を知っている側だけ**なので、
        # **そちらが `warn` を出す**（→ `LiveProgram#call`）。
        logger.debug(post: @name, slot: format_slot(slot), message: 'no text')
        return nil
      end
      return post(text, slot)
    end

    # ⚠ **枠の頭の時刻そのものから作る。**プロセスをまたいでも同じ枠なら同じ値。
    #
    # ⚠⚠ **これに畳んでもらうことを当てにしない**（#109）。🔴 **実機の Mastodon は
    # 同じキーの 2 通目を畳まず 500 を返した。**⚠ **素の POST では逆に畳まれず別々の
    # status ができる**という、噛み合わない 2 つの観測が取れている（応答ボディは
    # `Ginseng::GatewayError` が捨てるので読めない → #101）。⚠⚠ **キーは残す**
    # （**再起動をまたぐ重なりでは最後の砦**）が、**そこに寄りかからない。**
    def idempotency_key(slot)
      return [@name, slot.getutc.strftime('%Y%m%dT%H%M%SZ')].join('-')
    end

    def service
      @service ||= MastodonService.new
      return @service
    end

    def to_s
      return "#{@name} #{@timetable}"
    end

    private

    def validate
      unless @source.respond_to?(:call)
        raise Ginseng::ConfigError, "posting job: #{@name} source must respond to #call"
      end
      return if @tolerance < @timetable.interval
      # ⚠⚠ 枠の間隔が拾う幅以下だと、1 回の tick が複数の枠に跨がって取りこぼす。
      message = "posting job: #{@name} interval (#{@timetable.interval}s)"
      raise Ginseng::ConfigError, "#{message} must be longer than tolerance (#{@tolerance}s)"
    end

    # 🔴 **その枠をこの `exec` が持つと宣言する**（#109）。⚠ **既に処理した枠なら nil。**
    #
    # ⚠⚠ **結末で分けない。**成功でも失敗でも本文が無くても「処理した」と覚える。
    # ⚠ **落ちた枠を次の tick が拾い直す形にしない** — **再送は `HTTP#retryable?` が
    # 1 回の `exec` の中で済ませており**、⚠⚠ **その外にもう 1 枚あることを誰も
    # 設計していなかった**（それが #109 の 500 の正体）。⚠ **落とした分は後ろに
    # 詰めない**（→ docs/CLAUDE.md「投稿の欠落は詰めない」）と同じ考え方。
    #
    # 🔴 **覚えるのは 1 つでは足りない**（#126・Codex の指摘）。⚠⚠ **`Scheduler#tick` は
    # 先頭で `Time.now` を 1 回だけ取り、その値で全ジョブを回す。**⚠ **rufus の `every` は
    # 前の回を待たない**ので、**古い時刻を握った tick が、新しい tick より後にここへ
    # 到達しうる。**
    #
    # ⚠⚠ **遅れは判定に現れない** — `due_slot` が見るのは**tick が握った時刻**なので、
    # **どれだけ遅れて到達しても `(time - slot) < tolerance` は成立したまま。**
    # 🔴 **1 つしか覚えないと、A(枠 N) → B(枠 N+1) → 遅れた A(枠 N) で N をもう一度通す。**
    #
    # ⚠ **上限付きにする。**⚠⚠ **枠は増え続ける**ので、覚えたままにすると 8 時間で
    # 160 個溜まる（実害は無いが、上限の無い記憶を常駐に持たせない）。
    def claim(slot)
      return nil unless slot
      @claim_mutex.synchronize do
        return nil if @claimed.include?(slot)
        @claimed.push(slot)
        # ⚠ **古いほうから捨てる。**枠は前にしか進まないので、落ちるのは十分に古い枠。
        @claimed.shift while @claimed.size > CLAIM_MEMORY
        return slot
      end
    end

    # 枠の頭から `tolerance` 以内なら、その枠を返す。
    def due_slot(time = nil)
      time ||= Time.now
      slot = @timetable.slot_at(time)
      return nil unless slot
      return nil unless (time - slot) < @tolerance
      return slot
    end

    # ⚠ **`source` の失敗で常駐を落とさない。**本文が作れなければその枠は欠落する。
    #
    # ⚠⚠ **落ちたことを `Heartbeat` に残す。**ログにも出ているが、⚠ **監視から読むには
    # ログの置き場と書式に依存する**ので、痕跡の側にも 1 つ数を持たせる（→ #78）。
    #
    # ⚠ **`source` が nil や空文字を返したときは失敗にしない。**そちらは「今日は
    # 投稿しない」であって、**`source` は正しく動いている。**
    def create_text(slot)
      return @source.call(slot).to_s
    rescue => e
      logger.error(post: @name, slot: format_slot(slot), error: e)
      record(:failure, slot)
      return nil
    end

    # ⚠ **投稿の失敗で常駐を落とさない。**恒久的な失敗（401 等）も一時的な失敗も、
    # ここでは同じく「その枠は落ちた」として扱う。⚠ 再送そのものは `HTTP#retryable?`
    # が済ませた後なので、ここまで来た時点で諦める。
    def post(text, slot)
      response = service.post_status(
        text,
        visibility: @visibility,
        idempotency_key: idempotency_key(slot),
      )
      logger.info(post: @name, slot: format_slot(slot), status_id: response['id'])
      record(:success, slot)
      return response
    rescue => e
      logger.error(post: @name, slot: format_slot(slot), error: e)
      record(:failure, slot)
      return nil
    end

    # ⚠⚠ **痕跡が書けなくても枠を落とさない。**ここは観測のためだけの書き込みで、
    # ⚠ **これに失敗して投稿の側を巻き込むと、監視を足したせいで壊れることになる。**
    #
    # ⚠ **失敗にも冪等キーを渡す。**⚠⚠ **同じ枠が 2 回実行されることがある**
    # （初回 tick と `every` の重なり・再起動）ので、**成功だけ Mastodon 側で畳まれて
    # 失敗が二重に数えられると、落ちた枠 1 つで閾値を 2 つ消費する**（#81）。
    def record(outcome, slot)
      return Heartbeat.record_success if outcome == :success
      return Heartbeat.record_failure(slot: idempotency_key(slot))
    rescue => e
      logger.error(post: @name, heartbeat: outcome, error: e)
      return nil
    end

    def format_slot(slot)
      return slot.getutc.iso8601
    end

    def parse_tolerance(value)
      return value if value.is_a?(Numeric)
      seconds = Fugit::Duration.parse(value.to_s)&.to_sec
      raise Ginseng::ConfigError, "posting job: bad tolerance '#{value}'" unless seconds&.positive?
      return seconds
    end
  end
end
