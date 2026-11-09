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
    include ChatOwnerNotice

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

    # 🔴 **1 回目はペナルティにしない印**（→ クラスの冒頭）。
    GRACE_MARKS = ['provoke', 'backstage'].freeze

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
      # 🔴 **処理中の 1 通は、終わるのを少し待つ**（v1.0.1 のリリース前レビュー・3 観点）。⚠ 待っても終わらなければ
      # 殺し、その通知は起点に書かない（→ `handle_safely`）— 再起動のあと追いついて拾い直す。
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + JOIN_TIMEOUT
      sleep(0.1) while @busy && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      @thread.kill.join(JOIN_TIMEOUT)
      return nil
    rescue ThreadError
      return nil
    end

    # 受信の口から呼ばれる。⚠ **待たない**（積むだけ）。
    # @param received_at [Time] ⚠ 追いついた通知（#610）は投稿の時刻（窓の中の締め切りを効かせる）
    def call(notification, received_at = Time.now)
      # ⚠ **受けた時刻を一緒に積む**（窓の中の締め切りは、待ち行列で待った時間も含めて測る → #599）。
      return @queue.push([notification, received_at]) && nil if @queue.size < QUEUE_MAX
      logger.warn(chat: 'queue', message: 'dropped', notification_id: notification['id'])
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
      # ⚠ **LLM を呼ぶ前にも窓の締め切りを見る**（v1.0.1 のリリース前レビュー）— 追いついた通知（#610）は受けた時刻が
      # 投稿の時刻なので、窓の中では呼ぶ前から締め切りを過ぎていることが多い（費用と回数を使わない）。
      return done(:late_in_window, notification) if gate.late?(received_at)
      return respond(account, status, decision, notification, received_at)
    end

    # @param visibility [String] 渡した投稿のうち最も狭い公開範囲（→ `ChatThread#visibility`・#613）
    def reply_visibility(visibility)
      return REPLY_VISIBILITY.fetch(visibility.to_s, 'direct')
    end

    private

    # 🔴 **処理し終えた通知の ID を残す**（#610 → `MentionCatchUp`）。⚠⚠ **落ちたときも残す**（PR #633 の Codex の
    # P2）— 残さないと、再起動のあと追いついた同じ通知で LLM をもう一度呼び、回数も重ねて数える。
    #
    # ⚠⚠ **殺されたときは書かない**（v1.0.1 のリリース前レビュー）— `Thread#kill` でも `ensure` は走るので、返事を
    # 作っている途中で止めた通知が「処理し終えた」になり、再起動のあと二度と引かれなかった。
    def handle_safely(notification, received_at)
      @busy = true
      handle(notification, received_at)
    rescue => e
      # ⚠⚠ **1 通の失敗で処理のスレッドを止めない。**
      logger.error(chat: 'respond', notification_id: notification['id'], error: e)
      report_error(e, chat: 'respond')
    ensure
      killed = Thread.current.status == 'aborting'
      Heartbeat.checkpoint_notification(notification['id']) unless killed
      @busy = false
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
