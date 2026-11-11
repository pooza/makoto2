module Makoto
  # フォローされたら返し、外されたら外す（#606）。
  #
  # ## 決まり（2026-11-09・オーナー）
  #
  # - 🔴 **フォローの通知を受けたら、すぐ返す**（→ `MentionListener#on_follow`）
  # - 🔴 **外されたことは通知されないので、`/chat/followers/refresh` ごとに一覧を突き合わせる。**
  #   ⚠ あわせて、返しそびれた相手（常駐が止まっていた間のフォローなど）にも返す
  # - 🔴 **返事を止めた相手（`chat block`・#20）と、ペナルティ中の相手には返さない**（返していれば外す）。
  #   止めるのを解いたら、次の突き合わせで返す
  # - 🔴 **外す数に歯止め。**1 回の突き合わせで `/chat/follow/unfollow_limit` を超えて外すことになったら、
  #   **1 人も外さずに**エラーにする（ログと Sentry）。⚠ 返すほうは続ける。⚠⚠ **一覧が欠けたときに、まとめて外す事故を防ぐ。**
  #   ⚠ 一覧はどちらも「最後まで引けたときだけ」返る（→ `MastodonService#follower_ids`）
  # - ⚠ **鍵の掛かった相手へのフォローは承認待ちになり、フォロー中の一覧に出ない。**送り直さないように、
  #   承認待ちになった相手を覚えておく。🔴 **痕跡に残す**（PR #632 の Codex の P2）— 常駐のメモリだけだと、
  #   再起動で忘れて取り消せなくなり、`makoto chat follow-sync`（別のプロセス）からも見えない
  # - 🔴 **承認待ちかは、突き合わせのたびに `relationships` で引き直す**（#636）。⚠⚠ 覚えておくだけだと、相手に
  #   断られても集合から消えず、二度と返さなかった。⚠⚠ **フォローの応答の `requested` は当てにしない** — リモートの
  #   相手で承認が返ってこないとき、応答は `requested: false` なのに関係は承認待ちで、毎時送り直していた
  #   （2026-11-10 の本番・18〜20 人）。⚠ 返す前に関係を聞き、承認待ちなら送らない
  # - 🔴 **断られたら、送り直さない**（v1.0.2 のリリース前レビューの赤）。⚠⚠ 引き直すだけだと、断った人に
  #   毎時リクエストが届く。承認待ちだった相手が、フォロー中にも承認待ちにもなっていなければ断られたとみなし、
  #   痕跡に残す。⚠ **その人がフォローし直したら（通知・または一覧から一度消えたら）忘れて、また返す**
  # - ⚠ **関係が引けなければ、覚えている承認待ちで続ける**（同じレビューの黄）。返す・外すを止めない
  # - ⚠ **見るだけの CLI は痕跡に書かない**（`record: false`・#636 / #640）
  class FollowSync
    include Package

    # 待ちの設定が読めないときの待ち（秒・#611）。⚠ スレッドを死なせないための逃げ道。
    FALLBACK_INTERVAL = 3600

    # @param service [MastodonService] ⚠ テストが差し替える
    # @param roster [FollowerRoster] ⚠ テストが差し替える
    # @param repository [ChatRepository] 止めている相手を引く先。⚠ テストが差し替える
    # @param sleeper [#call] 待ち。⚠ テストが差し替える
    # @param record [Boolean] 痕跡に書くか。⚠ 見るだけの CLI は false（#636）
    def initialize(service: nil, roster: nil, repository: nil, sleeper: nil, record: true)
      @record = record
      @service = service
      @roster = roster
      @repository = repository
      @sleeper = sleeper || ->(seconds) {sleep(seconds)}
      @requested = Heartbeat.follow_requested.to_set
      @declined = Heartbeat.follow_declined.to_set
      @mutex = Mutex.new
      @stopping = false
    end

    # フォローを返すか（設定）。
    def self.follow_back?
      return Config.instance['/chat/follow/enabled'] == true
    end

    # 突き合わせのスレッドを起こすか。⚠ フォローの通知は受信の口で受けるので、受信を切ってあれば起こさない。
    def self.enabled?
      return follow_back? && MentionListener.enabled?
    end

    attr_reader :thread

    def start
      return nil unless self.class.enabled?
      @thread ||= Thread.new do
        Thread.current.name = 'makoto-follow'
        run
      end
      return @thread
    end

    # ⚠ **trap から呼ばれる**（Mutex を掴まない → `MentionListener#stop`）。
    def stop
      @stopping = true
      return nil unless @thread
      @thread.kill
      @thread.join(MentionListener::JOIN_TIMEOUT)
      return nil
    rescue ThreadError
      return nil
    end

    # 🔴 **スレッドを死なせない**（#611）。⚠⚠ 以前は `interval` が `sync` の rescue の外にあり、設定が読めないと
    # スレッドごと黙って死んだ（`report_on_exception` の出力は stderr ＝ `/dev/null`）。⚠ 読めなければ既定で待つ。
    def run
      until @stopping
        sync
        @sleeper.call(wait)
      end
    end

    # フォローの通知を受けた。⚠ **例外を上げない**（受信を止めない）。
    #
    # 🔴 **新しいフォロワーは、返すかどうかに関わらず一覧に足す**（#510 の門・`FollowerRoster`）。
    # ⚠ **フォローしてすぐ話しかけてくれた人を、一覧の引き直し（1 時間ごと）まで待たせない。**
    # @param account [Hash] 通知の `account`
    def on_follow(account)
      id = account['id']
      return nil if id.nil?
      roster.add(id)
      # ⚠ **フォローし直してくれたので、断られたことは忘れる。**返すかどうかの判定より先に（止めている間に
      # フォローし直した人も、解いたあとの突き合わせで返す・PR #649 の Codex の P2）。
      @mutex.synchronize {declined_change {@declined.delete(id.to_s)}}
      # ⚠ ボットのアカウントも返す（オーナーの決まりに例外が無い・返事は門が黙るので往復にならない）。
      return nil unless self.class.follow_back?
      return log(:skip, id, account['acct'], reason: 'stopped') if stopped?(id)
      return follow(id, account['acct'])
    rescue => e
      logger.error(follow: 'on_follow', error: e)
      report_error(e, follow: 'on_follow')
      return nil
    end

    # 一覧を突き合わせる。⚠ **例外を上げない**（引けなければ何もしない・次の回にまた見る）。
    # @return [Hash, nil] 返した・外した ID。⚠ 引けなかったなら nil
    #
    # 🔴 **1 人の失敗で、その回を止めない**（v1.0.0 のリリース前レビューの赤）。⚠⚠ Mastodon は引っ越した相手・
    # ブロック関係の相手に 403、凍結された相手に 404 を返す。一覧は毎回同じ順なので、1 人で止めると、
    # その後ろの全員にずっと返せない。⚠ 失敗した相手は ID をログに出し、次の回にまた試す。
    # ⚠ Sentry には送らない（恒久的に断られる相手がいると毎時鳴る）。
    #
    # @param force [Boolean] 外す数の歯止めを今回だけ外す（#614・オーナーが `makoto chat follow-sync --apply` で）
    def sync(force: false)
      to_follow, to_unfollow = preview
      return nil unless to_follow
      if !force && to_unfollow.size > unfollow_limit
        to_unfollow = over_limit(to_unfollow)
      else
        trace(:clear_follow_over_limit)
      end
      return apply(to_follow, to_unfollow)
    rescue => e
      logger.warn(follow: 'sync', message: 'could not sync', error_class: e.class.name, error: e)
      return nil
    end

    # 返す ID と外す ID（#614）。⚠ 何もしない。⚠ 一覧が引けなければ nil。
    # @return [Array<Set>, nil]
    def preview
      return nil unless roster.refresh
      following = service.following_ids.to_set(&:to_s)
      # ⚠ **フォロワーの写しは、フォロー中の一覧を引いた後に取る**（リリース前レビュー）。先に取ると、
      # その間に来たフォローを返した相手が「フォロー中なのにフォロワーでない」になり、すぐ外してしまう。
      return plan(roster.ids, following)
    end

    private

    # @return [Array<Set>] 返す ID と、外す ID
    def plan(followers, following)
      wanted = followers.reject {|id| stopped?(id)}.to_set
      # ⚠ **承認待ちも外す側に含める**（PR #608 の Codex の P2）。外す（`unfollow`）と承認待ちも取り消される。
      # 外しそびれると、対象でなくなった相手が後から承認して、次の突き合わせまでフォローが付く。
      requested = refresh_requested(wanted - following, following, wanted)
      # ⚠ 断った人のうち、フォロワーでなくなった人は忘れる（フォローし直したら、また返す）。
      declined = @mutex.synchronize {declined_change {@declined &= followers}}
      return wanted - following - requested - declined, (following | requested) - wanted
    end

    # 🔴 **承認待ちを `relationships` で引き直す**（#636 → クラスの冒頭）。⚠ 聞くのは、返す候補と覚えている承認待ち。
    # ⚠ 聞いている間に受信のスレッドが足したぶんは残す（聞いた ID だけを差し替える）。
    # @return [Set] 承認待ち
    def refresh_requested(candidates, following, wanted)
      known = @mutex.synchronize {@requested.dup}
      asked = (candidates | known) - following
      found = pending_ids(asked)
      return known unless found
      return @mutex.synchronize do
        decline((known & wanted) - following - found)
        requested_change {@requested.subtract(asked | following).merge(found)}
      end
    end

    # @return [Set, nil] ⚠ 引けなければ nil（→ 覚えている承認待ちで続ける）
    # ⚠ 空なら聞かない（`relationships` が 1 回も叩かない）。
    def pending_ids(ids)
      return service.relationships(ids.to_a).filter_map do |relationship|
        relationship['id'].to_s if relationship['requested'] && !relationship['following']
      end.to_set
    rescue => e
      logger.warn(follow: 'sync', message: 'could not get relationships',
        error_class: e.class.name, error: e)
      return nil
    end

    # 承認待ちだったのに、フォロー中にも承認待ちにもなっていない相手は断った。⚠ `@mutex` の中で呼ぶ。
    def decline(ids)
      ids.each {|id| log(:declined, id)}
      declined_change {@declined.merge(ids)}
    end

    def apply(to_follow, to_unfollow)
      unfollowed = to_unfollow.select {|id| attempt(:unfollow, id)}
      followed = to_follow.select {|id| attempt(:follow, id)}
      failed = (to_follow.size + to_unfollow.size) - (followed.size + unfollowed.size)
      logger.info(follow: 'sync', followed: followed.size, unfollowed: unfollowed.size, failed:)
      return {followed: followed.to_a, unfollowed: unfollowed.to_a}
    end

    # @return [Boolean] できたか。⚠ 例外を上げない（→ `sync`）
    def attempt(action, id)
      send(action, id)
      return true
    rescue => e
      logger.warn(follow: action.to_s, account_id: id.to_s, message: 'failed',
        error_class: e.class.name, error: e)
      return false
    end

    def follow(id, acct = nil)
      relationship = service.follow(id)
      # ⚠ 受信のスレッド（`on_follow`）と突き合わせのスレッドの両方から来るので、鍵を掛ける。
      # ⚠ **`requested` は当てにしない**（#636 → クラスの冒頭）。フォロー中にならなければ承認待ちとみなし、
      # 次の突き合わせで関係を聞き直す。
      unless relationship['following']
        @mutex.synchronize {requested_change {@requested.add(id.to_s)}}
      end
      return log(:follow, id, acct, requested: !relationship['following'])
    end

    def unfollow(id)
      service.unfollow(id)
      @mutex.synchronize {requested_change {@requested.delete(id.to_s)}}
      return log(:unfollow, id)
    end

    def log(action, id, acct = nil, **values)
      logger.info({follow: action.to_s, account_id: id.to_s, acct:}.compact.merge(values))
      return action
    end

    # 🔴 **超えたら 1 人も外さず、知らせる**（#614・2026-11-10 オーナー判断）。⚠⚠ 歯止めは「一覧が欠けて全員を
    # 外す」事故を防ぐためのもの。わざと踏まれると毎回止まるが、外すかは人が決める（`makoto chat follow-sync`）。
    # ⚠ `makoto status` の warning に出し、Sentry は止まり始めた 1 回だけ（毎時鳴らさない）。
    def over_limit(to_unfollow)
      error = Ginseng::GatewayError.new(
        "follow: #{to_unfollow.size} accounts to unfollow is over the limit (#{unfollow_limit})",
      )
      logger.error(follow: 'sync', message: error.message)
      first = Heartbeat.follow_over_limit.nil?
      trace(:record_follow_over_limit, to_unfollow.size, unfollow_limit)
      report_error(error, follow: 'sync') if first
      return Set.new
    end

    # 承認待ちを変えて、変わっていたら痕跡に書く。⚠ `@mutex` の中で呼ぶ。
    # @return [Set] 変えたあとの写し
    def requested_change
      before = @requested.dup
      yield
      trace(:record_follow_requested, @requested.to_a.sort) if @record && before != @requested
      return @requested.dup
    end

    # 断った相手を変えて、変わっていたら痕跡に書く。⚠ `@mutex` の中で呼ぶ。
    # @return [Set] 変えたあとの写し
    def declined_change
      before = @declined.dup
      yield
      trace(:record_follow_declined, @declined.to_a.sort) if @record && before != @declined
      return @declined.dup
    end

    # ⚠ **痕跡が書けなくても突き合わせは止めない**（観測のためのもの）。
    def trace(method, *)
      return unless @record
      Heartbeat.public_send(method, *)
    rescue => e
      logger.error(follow: 'sync', error: e)
    end

    # 返事を止めている相手か（#20 の `chat block` と、ペナルティ）。
    def stopped?(id)
      return true if repository.blocked(id)
      return gate.penalized?(id)
    end

    def unfollow_limit
      return config['/chat/follow/unfollow_limit'].to_i
    end

    def wait
      return interval
    rescue => e
      logger.error(follow: 'sync', message: 'bad interval', error: e)
      report_error(e, follow: 'sync')
      return FALLBACK_INTERVAL
    end

    def interval
      value = config['/chat/followers/refresh']
      seconds = Fugit::Duration.parse(value.to_s)&.to_sec
      return seconds if seconds&.positive?
      raise Ginseng::ConfigError, "chat: bad followers refresh '#{value}'"
    end

    def repository
      @repository ||= ChatRepository.new
      return @repository
    end

    def gate
      @gate ||= ChatGate.new(repository:)
      return @gate
    end

    def roster
      @roster ||= FollowerRoster.instance
      return @roster
    end

    def service
      @service ||= MastodonService.new
      return @service
    end
  end
end
