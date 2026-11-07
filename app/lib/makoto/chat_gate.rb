module Makoto
  # メンションに応答してよいかを決める門（#510）。🔴 **LLM を呼ぶ前に決める**（トークンを使わない）。
  #
  # ## 🔴 悪戯をする前の人を疑わない（2026-11-07・オーナー）
  #
  # - ⚠⚠ **フォローしてからの待ち時間・サーバーで絞る門は置かない**（新しいフォロワー全員を待たせない）
  # - 🔴 **ペナルティは悪戯の印が付いたあとにだけ掛ける。**印の回数で延ばす（`/chat/penalty`）
  # - ⚠ **相手ごとの上限はペナルティではなく、誰にでも同じに掛かる量の枠**
  #
  # ## 判定の順番
  #
  # | 順 | 条件 | 答え |
  # | --- | --- | --- |
  # | 1 | `bot` の印が付いたアカウント | 黙る（ボット同士の応酬を止める） |
  # | 2 | ペナルティの期間中 | 黙る |
  # | 3' | フォロワーかが分からない（一覧が一度も引けていない） | 黙る |
  # | 3 | フォロワーでない | **話せる条件を伝える**（決まった文）。⚠ その相手へは 1 日 1 回まで |
  # | 4 | 全体の 1 日の上限に届いた | 黙る（暴走したときの歯止め） |
  # | 5 | 相手ごとの上限に届いた | **上限を伝える**（決まった文）を 1 回だけ、あとは黙る |
  # | 6 | それ以外 | 返す（LLM を呼ぶ） |
  #
  # ⚠ **決まった文の中身はここに書かない**（正本は makoto-scripts・オーナーのレビュー）。
  class ChatGate
    include Package

    DAY = 86_400
    HOUR = 3600

    Decision = Data.define(:action, :reason) do
      # LLM を呼んで返す。
      def respond?
        return action == :respond
      end

      # 決まった文を返す（LLM は呼ばない）。
      def notice?
        return [:ask_follow, :limit_notice].include?(action)
      end

      def silent?
        return action == :silent
      end
    end

    # @param followed_by [#call] `(account_id) -> bool`。⚠ テストが差し替える
    def initialize(repository: nil, followed_by: nil)
      @repository = repository
      @followed_by = followed_by
    end

    # @param account [Hash] Mastodon の通知の `account`
    # @return [Decision]
    def decide(account, now: Time.now)
      id = account['id']
      return silent(:bot) if account['bot']
      return silent(:penalty) if penalized?(id, now)
      follower = follower_state(id)
      return silent(:followers_unknown) if follower.nil?
      return not_follower(id, now) unless follower
      return silent(:global_limit) if global_count(now) >= limit('/chat/limit/global/day')
      return over_limit(id, now) if over_limit?(id, now)
      return Decision.new(action: :respond, reason: nil)
    end

    # 返したことを記録する。⚠ **黙ったときは書かない**（数えるのは返したものだけ）。
    def record(account, decision, now: Time.now)
      return nil if decision.silent?
      return repository.record(account['id'], account['acct'], decision.action, now)
    end

    # 🔴 **悪戯の印を 1 つ付け、ペナルティを延ばす**（#18 が応答と一緒に受けた印を渡す）。
    #
    # ⚠ **期間は印の回数で決まる**（`/chat/penalty` の n 番目。尽きたら最後のもの）。
    # ⚠ **オーナーへの連絡はここではしない**（戻り値を見て呼び出し側が送る）。
    #
    # @return [Hash] 更新後の `chat_penalty` の行
    def mark(account, reason:, status_url: nil, now: Time.now)
      current = repository.penalty(account['id'])
      marks = current.to_h[:marks].to_i + 1
      return repository.save_penalty(account['id'], {
        acct: account['acct'].to_s,
        marks: marks,
        until_at: now + penalty_duration(marks),
        marked_at: now,
        reason: reason.to_s,
        status_url: status_url,
      })
    end

    def penalized?(account_id, now = Time.now)
      until_at = repository.penalty(account_id)&.dig(:until_at)
      return false unless until_at
      return until_at > now
    end

    # n 回目の印のペナルティの長さ（秒）。
    def penalty_duration(marks)
      durations = Array(config['/chat/penalty'])
      raise Ginseng::ConfigError, 'chat: /chat/penalty is empty' if durations.empty?
      return duration(durations[[marks, durations.size].min - 1])
    end

    private

    def repository
      @repository ||= ChatRepository.new
      return @repository
    end

    # フォロワーなら true・でなければ false・⚠ **分からなければ nil**（→ 黙る）。⚠⚠ **「フォロワーでない」に倒すと、Mastodon の不調のたびに
    # フォロワーへ「フォローしてくれたら」を返してしまう。**
    def follower_state(account_id)
      return (@followed_by || ->(id) {FollowerRoster.instance.include?(id)}).call(account_id)
    rescue Ginseng::GatewayError, Ginseng::AuthError => e
      logger.warn(chat: 'gate', message: 'followers unknown', error_class: e.class.name)
      return nil
    end

    def silent(reason)
      return Decision.new(action: :silent, reason: reason)
    end

    # ⚠ **同じ相手へは 1 日 1 回まで**（連打で同じ文を投稿させる遊びにしない）。
    def not_follower(id, now)
      asked = repository.count(:ask_follow, now - DAY, account_id: id)
      return silent(:not_follower) if asked.positive?
      return Decision.new(action: :ask_follow, reason: :not_follower)
    end

    def global_count(now)
      return repository.count(:respond, now - DAY)
    end

    def over_hour?(id, now)
      count = repository.count(:respond, now - HOUR, account_id: id)
      return count >= limit('/chat/limit/account/hour')
    end

    def over_day?(id, now)
      count = repository.count(:respond, now - DAY, account_id: id)
      return count >= limit('/chat/limit/account/day')
    end

    def over_limit?(id, now)
      return over_hour?(id, now) || over_day?(id, now)
    end

    # ⚠ **上限を伝えるのは 1 回だけ。**届いた窓（1 時間 / 1 日）の中で既に伝えていれば黙る。
    def over_limit(id, now)
      window = over_hour?(id, now) ? HOUR : DAY
      noticed = repository.count(:limit_notice, now - window, account_id: id)
      return silent(:account_limit) if noticed.positive?
      return Decision.new(action: :limit_notice, reason: :account_limit)
    end

    def limit(key)
      count = config[key]
      unless count.is_a?(Integer) && count.positive?
        raise Ginseng::ConfigError,
          "chat: bad #{key} '#{count}'"
      end
      return count
    end

    def duration(value)
      seconds = Fugit::Duration.parse(value.to_s)&.to_sec
      raise Ginseng::ConfigError, "chat: bad penalty '#{value}'" unless seconds&.positive?
      return seconds
    end
  end
end
