module Makoto
  class ChatResponderTest < TestCase
    OWN = '100'.freeze

    class FakeService
      attr_reader :posts
      attr_accessor :ancestors

      def initialize
        @posts = []
        @ancestors = []
      end

      def account
        return {'id' => OWN}
      end

      def status_ancestors(_id)
        raise Ginseng::GatewayError, 'mastodon returned 500' if @ancestors == :fail
        return @ancestors
      end

      def post_status(text, **options)
        @posts.push(options.merge(text: text))
        return {'id' => "posted-#{@posts.size}"}
      end
    end

    class FakeModel
      attr_reader :calls
      attr_accessor :reply

      def initialize(reply)
        @reply = reply
        @calls = []
      end

      def respond(messages)
        @calls.push(messages)
        return @reply
      end
    end

    def setup
      super
      @db = empty_db
      @repository = ChatRepository.new(@db)
      @followers = ['1']
      @service = FakeService.new
      @model = FakeModel.new(reply('はい、届いています。'))
      @scripts = MessageRepository.new(@db)
      @gate = ChatGate.new(repository: @repository, followed_by: ->(id) {@followers.include?(id)})
    end

    def responder
      return ChatResponder.new(service: @service, model: @model, gate: @gate, repository: @repository,
        messages: @scripts)
    end

    def reply(text, marks = [])
      return ChatModel::Reply.new(text: text, marks: marks, usage: {})
    end

    def notification(id: '9', account_id: '1', visibility: 'public', reply_to: nil, bot: false)
      return {
        'id' => "n#{id}",
        'type' => 'mention',
        'account' => {'id' => account_id, 'acct' => "user#{account_id}", 'bot' => bot},
        'status' => {
          'id' => id,
          'url' => "https://st2.precure.ml/@user#{account_id}/#{id}",
          'visibility' => visibility,
          'in_reply_to_id' => reply_to,
          'content' => '<p>@makoto こんにちは</p>',
          'account' => {'id' => account_id, 'acct' => "user#{account_id}"},
        },
      }
    end

    def script(type, body, slug)
      @scripts.upsert(slug: slug, type: type, body: body)
    end

    # 🔴 **公開の投稿には未収載で返す**（2026-11-08・オーナー）。
    def test_a_follower_gets_an_unlisted_reply
      assert_equal(:respond, responder.handle(notification))

      post = @service.posts.first

      assert_equal('@user1 はい、届いています。', post[:text])
      assert_equal('unlisted', post[:visibility])
      assert_equal('9', post[:in_reply_to_id])
      assert_equal('makoto-chat-9', post[:idempotency_key])
      assert_equal(1, @repository.count(:respond, Time.now - 60, account_id: '1'))
    end

    def test_visibility_follows_the_mention_but_never_widens
      subject = responder

      assert_equal(
        ['unlisted', 'unlisted', 'private', 'direct'],
        ['public', 'unlisted', 'private', 'direct'].map {|v| subject.reply_visibility(v)},
      )
    end

    def test_own_posts_and_duplicates_are_ignored
      subject = responder

      assert_equal(:own, subject.handle(notification(account_id: OWN)))
      assert_equal(:respond, subject.handle(notification))
      assert_equal(:duplicate, subject.handle(notification))
      assert_equal(1, @service.posts.size)
    end

    # 🔴 **失敗したら黙る**（何も投稿しない）。🔴 **ただし数える**（拒否・打ち切りも費用がかかる・
    # v1.0.0 のリリース前レビュー）。
    def test_a_model_failure_is_silence_but_counts
      @model.reply = nil

      assert_equal(:model_failed, responder.handle(notification))
      assert_empty(@service.posts)
      assert_equal(1, @repository.count(:respond, Time.now - 60))
    end

    # 🔴 **返事の中の第三者の `@` をメンションにしない**（v1.0.0 のリリース前レビューの赤）。
    def test_mentions_in_a_reply_are_neutralized
      @model.reply = reply('@someone さんにも、よろしく伝えてね。@foo@example.com にも。')
      responder.handle(notification)

      assert_equal(['@user1 ＠someone さんにも、よろしく伝えてね。＠foo＠example.com にも。'],
        @service.posts.map {|post| post[:text]})
    end

    # ⚠ 空の返事は投稿しないが、LLM を呼んだぶんは数える。
    def test_an_empty_reply_posts_nothing_but_counts
      @model.reply = reply('')

      assert_equal(:no_reply, responder.handle(notification))
      assert_empty(@service.posts)
      assert_equal(1, @repository.count(:respond, Time.now - 60))
    end

    # 🔴 **フォロワーでなければ、決まった文**（LLM は呼ばない）。⚠ 原稿が無ければ黙る。
    # 🔴 **強い窓の中では、遅れた返事を出さない**（#599）。⚠ LLM は呼んだので数える。
    # ⚠ 2026-11-08 は日曜（ニチアサの窓の中に受けた形）。
    def test_a_late_reply_in_the_strong_window_is_dropped_but_counted
      received_at = Time.parse('2026-11-08 08:40:00 +0900')

      assert_equal(:late_in_window, responder.handle(notification, received_at))
      assert_empty(@service.posts)
      assert_equal(1, @repository.count(:respond, Time.now - 60))
    end

    # ⚠ 時刻を両方渡して決める（いまの時刻で結果が変わらないように）。
    def test_late_depends_on_the_deadline_and_the_strong_window
      subject = @gate
      sunday = Time.parse('2026-11-08 08:40:00 +0900')
      monday = Time.parse('2026-11-09 08:40:00 +0900')

      assert_true(subject.late?(sunday, sunday + 31))
      assert_false(subject.late?(sunday, sunday + 29))
      # 窓の外は待ってでも返す。
      assert_false(subject.late?(monday, monday + 120))
      # 窓の終わり際に受け、窓の後に着く返事も捨てる。窓の始まる直前に受け、窓の中で着く返事も同じ。
      assert_true(subject.late?(Time.parse('2026-11-08 08:59:50 +0900'),
        Time.parse('2026-11-08 09:00:40 +0900')))
      assert_true(subject.late?(Time.parse('2026-11-08 08:29:50 +0900'),
        Time.parse('2026-11-08 08:30:40 +0900')))
    end

    def test_a_non_follower_gets_the_scripted_notice
      assert_equal(:no_notice_script, responder.handle(notification(account_id: '2')))
      assert_empty(@service.posts)

      script('chat_ask_follow', 'フォローしてくれたら、お話しできます。', 'chat-ask-follow-01')

      assert_equal(:ask_follow, responder.handle(notification(id: '10', account_id: '2')))
      assert_equal('@user2 フォローしてくれたら、お話しできます。', @service.posts.first[:text])
      assert_empty(@model.calls)
    end

    def test_the_thread_is_passed_to_the_model
      own = {'id' => OWN, 'acct' => 'makoto'}
      @service.ancestors = [{'id' => '1', 'content' => '<p>おはよう！</p>', 'account' => own}]
      responder.handle(notification(reply_to: '1'))

      assert_equal([{role: 'user', content: "〔あなたの投稿〕\nおはよう！\n\n〔それへの返信〕\nこんにちは"}],
        @model.calls.first)
    end

    # 🔴 **祖先が狭ければ、返事も狭くする**（#613）。
    def test_the_reply_is_not_wider_than_the_ancestors
      own = {'id' => OWN, 'acct' => 'makoto'}
      @service.ancestors = [{'id' => '1', 'content' => '<p>おはよう</p>', 'account' => own, 'visibility' => 'private'}]

      assert_equal(:respond, responder.handle(notification(reply_to: '1')))
      assert_equal('private', @service.posts.first[:visibility])
    end

    # ⚠ 祖先が引けなければ、その 1 通だけで答える。
    def test_unavailable_ancestors_do_not_stop_the_reply
      @service.ancestors = :fail

      assert_equal(:respond, responder.handle(notification(reply_to: '1')))
      assert_equal([{role: 'user', content: 'こんにちは'}], @model.calls.first)
    end

    # 🔴 **舞台裏を訊かれたら、そのスレッドは打ち切る**。⚠ **1 回目は印にしない**。
    def test_backstage_closes_the_thread_and_marks_only_the_second_time
      @model.reply = reply('このアカウントの真琴は、AI が演じています。', ['backstage'])
      subject = responder

      assert_equal(:respond, subject.handle(notification(id: '9')))
      assert_true(@repository.closed_thread?('9', '1'))
      assert_nil(@repository.penalty('1'))
      assert_equal(:closed_thread, subject.handle(notification(id: '10', reply_to: '9')))
      # 🔴 **打ち切るのはその相手との会話だけ**（同じ投稿に返信した別の人には返す・リリース前レビューの赤）。
      @followers.push('2')
      @model.reply = reply('はい、届いています。')

      assert_equal(:respond, subject.handle(notification(id: '12', account_id: '2', reply_to: '9')))
      @model.reply = reply('このアカウントの真琴は、AI が演じています。', ['backstage'])

      assert_equal(:respond, subject.handle(notification(id: '11')))
      assert_equal(1, @repository.penalty('1')[:marks])
      owner = @service.posts.find {|post| post[:visibility] == 'direct'}

      assert_match(/\A@pooza user1 に印が付きました（舞台裏を繰り返し訊いた・1 回目/, owner[:text])
      # 🔴 **相手をメンションしない**（DM が相手にも届く・PR #589 の Codex の P1）。
      assert_equal(['@pooza'], owner[:text].scan(%r{(?<![\w/])@[\w.@-]+}))
    end

    # 🔴 **言わせようとしたら、1 回目は数えるだけ**（返事はする・言葉遊びもある・2026-11-08 オーナー）。
    # 猶予の期間の中の 2 回目で印を付け、オーナーへ知らせる。
    def test_provoke_marks_only_the_second_time_and_tells_the_owner
      script('chat_owner_notice', '{acct} さんが{reason}みたい。{marks} 回目です。{url}', 'chat-owner-01')
      @model.reply = reply('そういうのは、ちょっと。', ['provoke'])
      subject = responder

      assert_equal(:respond, subject.handle(notification(id: '9')))
      assert_equal(['@user1 そういうのは、ちょっと。'], @service.posts.map {|post| post[:text]})
      assert_false(@gate.penalized?('1'))

      assert_equal(:respond, subject.handle(notification(id: '10')))
      texts = @service.posts.drop(1).map {|post| post[:text]}

      assert_equal(['@pooza user1 さんが繰り返し言わせようとしたみたい。1 回目です。https://st2.precure.ml/@user1/10',
        '@user1 そういうのは、ちょっと。'], texts)
      assert_true(@gate.penalized?('1'))
      assert_false(@repository.closed_thread?('9', '1'))
    end

    # ⚠ **猶予は種類ごと**（舞台裏の 1 回目のあとの、言わせようとした 1 回目は印にしない）。
    def test_grace_is_counted_per_kind
      subject = responder
      @model.reply = reply('このアカウントの真琴は、AI が演じています。', ['backstage'])
      subject.handle(notification(id: '9'))
      @model.reply = reply('そういうのは、ちょっと。', ['provoke'])
      subject.handle(notification(id: '10'))

      assert_nil(@repository.penalty('1'))
    end

    # 🔴 **運営を名乗ったら、返事をせず・打ち切り・印**。
    def test_impersonate_is_silent_closed_and_marked
      @model.reply = reply('', ['impersonate'])

      assert_equal(:no_reply, responder.handle(notification))
      assert_true(@repository.closed_thread?('9', '1'))
      assert_equal(1, @repository.penalty('1')[:marks])
      assert_equal(['direct'], @service.posts.map {|post| post[:visibility]})
    end

    # 🔴 **ペナルティ中は 1 回だけ伝えて、あとは黙る**（2026-11-09・オーナー）。⚠ LLM は呼ばない。
    def test_a_penalized_account_is_told_once
      script('chat_penalty_notice', 'しばらくお返事はお休みします。', 'chat-penalty-notice-1')
      @gate.mark({'id' => '1', 'acct' => 'user1'}, reason: 'provoke')
      subject = responder

      assert_equal(:penalty_notice, subject.handle(notification(id: '9')))
      assert_equal(:penalty, subject.handle(notification(id: '10')))
      assert_equal(['@user1 しばらくお返事はお休みします。'], @service.posts.map {|post| post[:text]})
      assert_empty(@model.calls)
    end

    # 🔴 **ブロックリストに載った相手にも 1 回だけ伝える**（#20）。⚠ 原稿が無ければ黙る。
    def test_a_blocked_account_is_told_once
      @repository.block('1', 'user1')
      subject = responder

      assert_equal(:no_notice_script, subject.handle(notification(id: '9')))
      script('chat_block_notice', 'これからはお返事できません。', 'chat-block-notice-1')

      assert_equal(:block_notice, subject.handle(notification(id: '10')))
      assert_equal(:blocked, subject.handle(notification(id: '11')))
      assert_equal(1, @service.posts.size)
      assert_empty(@model.calls)
    end

    def test_the_queue_is_capped
      subject = responder
      (ChatResponder::QUEUE_MAX + 3).times {|i| subject.call(notification(id: i.to_s))}

      assert_equal(ChatResponder::QUEUE_MAX, subject.instance_variable_get(:@queue).size)
    end

    def test_it_is_enabled_only_with_a_key
      config['/chat/enabled'] = true
      config['/anthropic/api_key'] = ''

      assert_false(ChatResponder.enabled?)
      config['/anthropic/api_key'] = 'sk-ant-test'

      assert_true(ChatResponder.enabled?)
      config['/chat/enabled'] = false

      assert_false(ChatResponder.enabled?)
    end

    # 🔴 **処理し終えた通知の ID を残す**（#610 → `MentionCatchUp`）。⚠ 返事をしなかった通知も。
    def test_the_handled_notification_id_is_recorded
      FileUtils.rm_f(Heartbeat.path)
      subject = responder
      subject.send(:handle_safely, notification.merge('id' => '21'), Time.now)

      assert_equal('21', Heartbeat.notification_id)
      subject.send(:handle_safely, notification(account_id: OWN).merge('id' => '22'), Time.now)

      assert_equal('22', Heartbeat.notification_id)
    ensure
      FileUtils.rm_f(Heartbeat.path)
    end
  end
end
