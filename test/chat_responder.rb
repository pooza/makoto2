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
        ['public', 'unlisted', 'private', 'direct'].map {|v| subject.reply_visibility({'visibility' => v})},
      )
    end

    def test_own_posts_and_duplicates_are_ignored
      subject = responder

      assert_equal(:own, subject.handle(notification(account_id: OWN)))
      assert_equal(:respond, subject.handle(notification))
      assert_equal(:duplicate, subject.handle(notification))
      assert_equal(1, @service.posts.size)
    end

    # 🔴 **失敗したら黙る**（何も投稿しない・数えない）。
    def test_a_model_failure_is_silence
      @model.reply = nil

      assert_equal(:model_failed, responder.handle(notification))
      assert_empty(@service.posts)
      assert_equal(0, @repository.count(:respond, Time.now - 60))
    end

    # ⚠ 空の返事は投稿しないが、LLM を呼んだぶんは数える。
    def test_an_empty_reply_posts_nothing_but_counts
      @model.reply = reply('')

      assert_equal(:no_reply, responder.handle(notification))
      assert_empty(@service.posts)
      assert_equal(1, @repository.count(:respond, Time.now - 60))
    end

    # 🔴 **フォロワーでなければ、決まった文**（LLM は呼ばない）。⚠ 原稿が無ければ黙る。
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
      assert_true(@repository.closed_thread?('9'))
      assert_nil(@repository.penalty('1'))
      assert_equal(:closed_thread, subject.handle(notification(id: '10', reply_to: '9')))

      assert_equal(:respond, subject.handle(notification(id: '11')))
      assert_equal(1, @repository.penalty('1')[:marks])
      owner = @service.posts.find {|post| post[:visibility] == 'direct'}

      assert_match(/\A@pooza user1 に印が付きました（舞台裏を繰り返し訊いた・1 回目/, owner[:text])
      # 🔴 **相手をメンションしない**（DM が相手にも届く・PR #589 の Codex の P1）。
      assert_equal(['@pooza'], owner[:text].scan(%r{(?<![\w/])@[\w.@-]+}))
    end

    # 🔴 **言わせようとしたら印を付け、オーナーへ知らせる**（返事はする）。
    def test_provoke_marks_and_tells_the_owner_with_the_script
      script('chat_owner_notice', '{acct} さんが{reason}みたい。{marks} 回目です。{url}', 'chat-owner-01')
      @model.reply = reply('そういうのは、ちょっと。', ['provoke'])

      assert_equal(:respond, responder.handle(notification))

      texts = @service.posts.map {|post| post[:text]}

      assert_equal(['@pooza user1 さんが言わせようとしたみたい。1 回目です。https://st2.precure.ml/@user1/9',
        '@user1 そういうのは、ちょっと。'], texts)
      assert_true(@gate.penalized?('1'))
      assert_false(@repository.closed_thread?('9'))
    end

    # 🔴 **運営を名乗ったら、返事をせず・打ち切り・印**。
    def test_impersonate_is_silent_closed_and_marked
      @model.reply = reply('', ['impersonate'])

      assert_equal(:no_reply, responder.handle(notification))
      assert_true(@repository.closed_thread?('9'))
      assert_equal(1, @repository.penalty('1')[:marks])
      assert_equal(['direct'], @service.posts.map {|post| post[:visibility]})
    end

    def test_a_penalized_account_gets_nothing
      @gate.mark({'id' => '1', 'acct' => 'user1'}, reason: 'provoke')

      assert_equal(:penalty, responder.handle(notification))
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
  end
end
