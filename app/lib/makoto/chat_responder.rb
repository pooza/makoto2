module Makoto
  # 受けたメンションに返事をする（#18）。受信の口（`MentionListener`）の `handler` になる。
  #
  # ## 流れ
  #
  # 1. 🔴 **門**（`ChatGate`・LLM を呼ばない）— 黙る／決まった文を返す／返す
  # 2. 前のやりとり（祖先）を引いて会話を組む（`ChatThread`）。🔴 **打ち切った会話なら黙る**
  # 3. LLM に返事と印を作らせる（`ChatModel`）。🔴 **失敗したら黙る**
  # 4. 印を処理する（下記）
  # 5. 返事を投稿する。🔴 **公開の投稿には未収載で返す**（2026-11-08・オーナー）
  #    🔴 **強い窓（日曜の朝）の中では、受けてから `/chat/commentary/deadline` を超えた返事を捨てる**（#599）
  #
  # ## 印の扱い（#510）
  #
  # | 印 | 会話 | ペナルティ（`ChatGate#mark`）とオーナーへの DM |
  # | --- | --- | --- |
  # | `provoke`（言わせようとした） | 続ける | ⚠ **1 回目は付けない**（下記） |
  # | `backstage`（舞台裏を訊いた） | 🔴 **打ち切る** | ⚠ **1 回目は付けない**（下記） |
  # | `impersonate`（運営を名乗った） | 打ち切る | 付ける（🔴 しばらく無視する ＝ ペナルティ） |
  #
  # 🔴 **`provoke` と `backstage` は、`/chat/grace/window` の中の 2 回目から付ける**（種類ごとに数える）。
  # ⚠ 小さな子が素朴に訊く・言葉遊びをすることもある（しりとりの「おしっこ」など・2026-11-08 オーナー）。
  # 1 回の悪ふざけは真琴がかわせば済む。⚠ `impersonate` は 1 回目から付ける。
  # ⚠ **オーナーへの連絡は知らせるだけ**（フォローを外すのはオーナー・A から始める）。
  #
  # ## 🔴 受信を止めない
  #
  # ⚠⚠ **LLM は数秒かかる**ので、受信のスレッドでは待たない。**別のスレッドで 1 本ずつ**処理する
  # （順番が保たれ、回数の上限の数え方も崩れない）。⚠ 溜まりすぎたら捨てる（`QUEUE_MAX`）。
  #
  # ⚠⚠ **本文をログに出さない**（相手の投稿も MAKOTO の返事も）。
  class ChatResponder
    include Package

    # ⚠ 溜まった通知の上限。⚠ 門の全体の上限（1 日 150 回）より十分小さければよい。
    QUEUE_MAX = 50
    SEEN_MAX = 500
    JOIN_TIMEOUT = 5

    # 🔴 **返事の公開範囲**（2026-11-08・オーナー）。⚠ 会話でタイムラインを埋めない。
    REPLY_VISIBILITY = {
      'public' => 'unlisted',
      'unlisted' => 'unlisted',
      'private' => 'private',
      'direct' => 'direct',
    }.freeze

    OWNER_NOTICE_TYPE = 'chat_owner_notice'.freeze

    # 🔴 **1 回目はペナルティにしない印**（→ クラスの冒頭）。
    GRACE_MARKS = ['provoke', 'backstage'].freeze

    # オーナーへの DM に入れる印の言い方。⚠ 真琴の口調の文ではない（原稿の `{reason}` に入る）。
    REASONS = {
      'provoke' => '繰り返し言わせようとした',
      'backstage' => '舞台裏を繰り返し訊いた',
      'impersonate' => '運営を名乗った',
    }.freeze

    attr_reader :thread

    def initialize(service: nil, model: nil, gate: nil, repository: nil, messages: nil)
      @service = service
      @model = model
      @gate = gate
      @repository = repository
      @messages = messages
      @queue = Thread::Queue.new
      @seen = []
    end

    # 設定で応答を切っていないか。⚠ キーの有無は見ない（→ `.enabled?`）。
    def self.configured?
      return Config.instance['/chat/enabled'] == true
    end

    # 🔴 **返事をするか。**⚠ キーが無い・受信を切っているなら、受けても返さない（受信は続く）。
    def self.enabled?
      return configured? && ChatModel.enabled? && MentionListener.enabled?
    end

    def start
      @thread ||= Thread.new do
        Thread.current.name = 'makoto-chat'
        while (item = @queue.pop)
          handle_safely(*item)
        end
      end
      return @thread
    end

    # ⚠ **TERM の trap から呼ばれる**ので Mutex を掴まない（→ `MentionListener#stop`）。
    def stop
      return nil unless @thread
      @thread.kill
      @thread.join(JOIN_TIMEOUT)
      return nil
    rescue ThreadError
      return nil
    end

    # 受信の口から呼ばれる。⚠ **待たない**（積むだけ）。
    def call(notification)
      if @queue.size >= QUEUE_MAX
        logger.warn(chat: 'queue', message: 'dropped', notification_id: notification['id'])
        return nil
      end
      # ⚠ **受けた時刻を一緒に積む**（窓の中の締め切りは、待ち行列で待った時間も含めて測る → #599）。
      @queue.push([notification, Time.now])
      return nil
    end

    # 1 通を処理する（⚠ テストはこちらを直に呼ぶ）。
    # @return [Symbol] 何をしたか（ログと同じ）
    def handle(notification, received_at = Time.now)
      status = notification['status']
      account = notification['account']
      return done(:unreadable, notification) unless status.is_a?(Hash) && account.is_a?(Hash)
      return done(:own, notification) if account['id'].to_s == own_id
      return done(:duplicate, notification) if seen?(status['id'])
      decision = gate.decide(account)
      return done(decision.reason, notification) if decision.silent?
      return notice(account, status, decision, notification) if decision.notice?
      return respond(account, status, decision, notification, received_at)
    end

    # @param visibility [String] 渡した投稿のうち最も狭い公開範囲（→ `ChatThread#visibility`・#613）
    def reply_visibility(visibility)
      return REPLY_VISIBILITY.fetch(visibility.to_s, 'direct')
    end

    private

    def handle_safely(notification, received_at)
      handle(notification, received_at)
    rescue => e
      # ⚠⚠ **1 通の失敗で処理のスレッドを止めない。**
      logger.error(chat: 'respond', notification_id: notification['id'], error: e)
      report_error(e, chat: 'respond')
    end

    def respond(account, status, decision, notification, received_at)
      thread = ChatThread.new(status, ancestors(status), own_id: own_id)
      closed = repository.closed_thread?(thread.root_id, account['id'])
      return done(:closed_thread, notification) if closed
      messages = thread.messages
      return done(:empty, notification) if messages.empty?
      reply = model.respond(messages)
      # ⚠ **LLM を呼んだぶんは数える**（黙ると決めた返事も・費用がかかったので）。
      # 🔴 **失敗も数える**（v1.0.0 のリリース前レビュー）。⚠⚠ 拒否・上限での打ち切り・読めない JSON も
      # 費用はかかる。数えないと、拒否を引き出す文の繰り返しが回数の上限をすり抜ける。
      gate.record(account, decision)
      return done(:model_failed, notification) unless reply
      handle_marks(account, status, thread, reply.marks)
      return done(:no_reply, notification, marks: reply.marks) if reply.silent?
      return done(:late_in_window, notification, marks: reply.marks) if gate.late?(received_at)
      post_reply(account, status, reply.text, thread)
      return done(:respond, notification, marks: reply.marks)
    end

    def notice(account, status, decision, notification)
      body = pick(ChatGate::NOTICES.fetch(decision.action))
      # ⚠ **原稿が無ければ黙る**（決まった文をコードに持たない・正本は makoto-scripts）。
      return done(:no_notice_script, notification, level: :warn) unless body
      post_reply(account, status, body)
      gate.record(account, decision)
      return done(decision.action, notification)
    end

    def handle_marks(account, status, thread, marks)
      closing = marks & ['backstage', 'impersonate']
      repository.close_thread(thread.root_id, account['id'], closing.join(',')) if closing.any?
      reasons = marks & ['impersonate']
      (marks & GRACE_MARKS).each do |mark|
        reasons.push(mark) if marked_before?(account, mark)
        repository.record(account['id'], account['acct'], mark)
      end
      return if reasons.empty?
      penalty = gate.mark(account, reason: reasons.join(','), status_url: status['url'])
      notify_owner(account, status, penalty, reasons)
    end

    # ⚠ その種類の印が、猶予の期間の中で前にも付いていたか（今回のぶんを記録する前に見る）。
    def marked_before?(account, mark)
      since = Time.now - duration(config['/chat/grace/window'])
      return repository.count(mark, since, account_id: account['id']).positive?
    end

    # 🔴 **オーナーへ DM で知らせる**（#510）。⚠ モデレーションの判断に足りる材料を載せる。
    #
    # 🔴🔴 **相手をメンションしない**（PR #589 の Codex の P1）。⚠⚠ **DM は本文でメンションした全員に
    # 届く**ので、`@相手` と書くと、オーナーだけへの知らせ（理由・回数・期限）が当の相手にも届く。
    # ⚠ `{acct}` は先頭の `@` を外す（`user@host` は `@` の前が文字なのでメンションにならない）。
    def notify_owner(account, status, penalty, reasons)
      values = {
        acct: account['acct'].to_s.delete_prefix('@'),
        url: status['url'].to_s,
        marks: penalty[:marks].to_s,
        until: penalty[:until_at]&.strftime('%Y-%m-%d %H:%M').to_s,
        reason: reasons.map {|reason| REASONS.fetch(reason)}.join('・'),
      }
      body = pick(OWNER_NOTICE_TYPE)
      unless body
        # ⚠ 原稿が無くても知らせは落とさない（オーナーにだけ届く・口調の文でなくてよい）。
        logger.warn(chat: 'owner', message: 'no script, sending a plain notice')
        body = '{acct} に印が付きました（{reason}・{marks} 回目・{until} まで応答しません）{url}'
      end
      text = "@#{config['/chat/owner']} #{render(body, values)}"
      key = "makoto-chat-owner-#{status['id']}"
      service.post_status(text, visibility: 'direct', idempotency_key: key)
      logger.info(chat: 'owner', acct: account['acct'], reasons: reasons, marks: penalty[:marks])
    end

    def render(body, values)
      return body.gsub(/\{(\w+)\}/) do
        values.fetch(Regexp.last_match(1).to_sym, Regexp.last_match(0))
      end
    end

    # 🔴 **本文の `@` はメンションにしない**（→ `ChatThread.unmention`）。⚠ 宛先の `@相手` だけをここで付ける。
    # 🔴 **会話への返事は、渡した投稿のうち最も狭い公開範囲に合わせる**（→ `ChatThread#visibility`・#613）。
    # ⚠ 決まった文（`notice`）は祖先を引かないので、メンションの公開範囲で返す（会話の中身を含まない）。
    def post_reply(account, status, text, thread = nil)
      service.post_status(
        "@#{account['acct']} #{ChatThread.unmention(text)}",
        visibility: reply_visibility(thread ? thread.visibility : status['visibility']),
        in_reply_to_id: status['id'],
        # ⚠ **同じ通知に 2 度返さない**（繋ぎ直しで同じ通知が届いても畳まれる）。
        idempotency_key: "makoto-chat-#{status['id']}",
      )
    end

    # ⚠ **引けなければ空**（その 1 通だけで答える）。
    def ancestors(status)
      return [] unless status['in_reply_to_id']
      return service.status_ancestors(status['id'])
    rescue Ginseng::GatewayError, Ginseng::AuthError => e
      logger.warn(chat: 'thread', message: 'ancestors unavailable', status_id: status['id'],
        error_class: e.class.name)
      return []
    end

    def pick(type)
      bodies = messages_repository.by_type(type).map {|record| record[:body]}
      return bodies.empty? ? nil : bodies.sample
    end

    def seen?(id)
      return true if @seen.include?(id.to_s)
      @seen.push(id.to_s)
      @seen.shift while @seen.size > SEEN_MAX
      return false
    end

    def done(result, notification, level: :info, **fields)
      logger.send(level, chat: 'respond', result: result, notification_id: notification['id'],
        acct: notification.dig('account', 'acct'), **fields)
      return result
    end

    def own_id
      @own_id ||= service.account['id'].to_s
      return @own_id
    end

    def service
      @service ||= MastodonService.new
      return @service
    end

    def model
      @model ||= ChatModel.new
      return @model
    end

    def repository
      @repository ||= ChatRepository.new
      return @repository
    end

    def gate
      @gate ||= ChatGate.new(repository: repository)
      return @gate
    end

    def messages_repository
      @messages ||= MessageRepository.new
      return @messages
    end

    def duration(value)
      seconds = Fugit::Duration.parse(value.to_s)&.to_sec
      raise Ginseng::ConfigError, "chat: bad duration '#{value}'" unless seconds&.positive?
      return seconds
    end
  end
end
