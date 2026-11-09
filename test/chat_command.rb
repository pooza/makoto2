module Makoto
  # チャットのモデレーションの運用操作（#510 / #20）。⚠ オーナーが手で叩く口なので、分岐を縛る（#617）。
  class ChatCommandTest < TestCase
    # `lookup_account` だけを持つ作り物。⚠ 引けない acct は nil（本物と同じ）。
    class FakeMastodon
      attr_reader :lookups

      def initialize(accounts)
        @accounts = accounts
        @lookups = []
      end

      def lookup_account(acct)
        @lookups.push(acct)
        return @accounts[acct.to_s.delete_prefix('@')]
      end
    end

    def setup
      super
      @repository = ChatRepository.new(Database.migrate(Database.connect('sqlite:/')))
      @mastodon = FakeMastodon.new(
        'cure_sword' => {'id' => '7', 'acct' => 'cure_sword'},
        'cure_sword@st2.precure.ml' => {'id' => '7', 'acct' => 'cure_sword'},
      )
    end

    def command(options = {}, repository: @repository)
      subject = ChatCommand.new
      subject.options = options
      subject.instance_variable_set(:@repository, repository)
      subject.instance_variable_set(:@mastodon, @mastodon)
      return subject
    end

    # @return [Array] 標準出力・標準エラー・終了したか
    def run_command
      out = $stdout
      err = $stderr
      $stdout = StringIO.new
      $stderr = StringIO.new
      exited = false
      begin
        yield
      rescue SystemExit
        exited = true
      end
      return [$stdout.string, $stderr.string, exited]
    ensure
      $stdout = out
      $stderr = err
    end

    def test_block_and_list
      out, _, exited = run_command {command({note: 'しつこい'}).block('cure_sword')}

      assert_false(exited)
      assert_match('blocked: @cure_sword (id: 7)', out)
      assert_equal('しつこい', @repository.blocked('7')[:note])

      out, = run_command {command.blocks}

      assert_match(/@cure_sword since .* しつこい/, out)
    end

    def test_blocks_when_empty
      out, = run_command {command.blocks}

      assert_equal("(none)\n", out)
    end

    # ⚠ 二重に載せない（`exit 1`）。
    def test_block_twice
      run_command {command.block('cure_sword')}
      _, err, exited = run_command {command.block('cure_sword')}

      assert_true(exited)
      assert_match('もう載っています: @cure_sword', err)
      assert_equal(1, @repository.all_blocks.size)
    end

    def test_block_an_unknown_account
      _, err, exited = run_command {command.block('nobody')}

      assert_true(exited)
      assert_match('アカウントが見つかりません: nobody', err)
      assert_empty(@repository.all_blocks)
    end

    # 載せたときの acct で引けたら、Mastodon に問い合わせない。
    def test_unblock_by_the_stored_acct
      @repository.block('7', 'cure_sword')
      out, _, exited = run_command {command.unblock('cure_sword')}

      assert_false(exited)
      assert_match('unblocked: @cure_sword', out)
      assert_nil(@repository.blocked('7'))
      assert_empty(@mastodon.lookups)
    end

    # ⚠ 載せたときの acct（ローカルはホスト無し）で引けなければ、Mastodon で引き直して ID で探す。
    def test_unblock_falls_back_to_the_lookup
      @repository.block('7', 'cure_sword')
      out, _, exited = run_command {command.unblock('cure_sword@st2.precure.ml')}

      assert_false(exited)
      assert_match('unblocked: @cure_sword', out)
      assert_equal(['cure_sword@st2.precure.ml'], @mastodon.lookups)
      assert_nil(@repository.blocked('7'))
    end

    def test_unblock_an_account_not_listed
      _, err, exited = run_command {command.unblock('cure_sword')}

      assert_true(exited)
      assert_match('載っていません: cure_sword', err)
    end

    def save_penalty
      @repository.save_penalty('7', {
        acct: 'cure_sword',
        marks: 2,
        until_at: Time.now + 3600,
        marked_at: Time.now,
        reason: 'provoke',
        status_url: 'https://st2.precure.ml/@cure_sword/1',
      })
    end

    def test_penalties
      save_penalty
      out, = run_command {command.penalties}

      assert_match(%r{@cure_sword marks: 2 until .* reason: provoke https://st2\.precure\.ml/@cure_sword/1}, out)
    end

    def test_penalties_when_empty
      out, = run_command {command.penalties}

      assert_equal("(none)\n", out)
    end

    # ⚠ DB を作る前（`rake migration:run` 前）は、案内して `exit 1`。
    def test_penalties_before_the_migration
      bare = ChatRepository.new(Database.connect('sqlite:/'))
      _, err, exited = run_command {command(repository: bare).penalties}

      assert_true(exited)
      assert_match('rake migration:run', err)
    end

    # ⚠ 印の回数ごと消す。
    def test_forgive
      save_penalty
      out, _, exited = run_command {command.forgive('@cure_sword')}

      assert_false(exited)
      assert_match('forgiven: @cure_sword (marks: 2)', out)
      assert_nil(@repository.penalty('7'))
    end

    def test_forgive_without_a_penalty
      _, err, exited = run_command {command.forgive('cure_sword')}

      assert_true(exited)
      assert_match('ペナルティの記録がありません: cure_sword', err)
    end

    # `preview` / `sync` だけを持つ作り物（#614）。
    class FakeSync
      attr_reader :forced

      def initialize(plan)
        @plan = plan
      end

      def preview
        return @plan
      end

      def sync(force: false)
        @forced = force
        return nil unless @plan
        return {followed: @plan[0].to_a, unfollowed: @plan[1].to_a}
      end
    end

    def sync_command(plan, options = {})
      subject = command(options)
      @sync = FakeSync.new(plan)
      subject.instance_variable_set(:@syncer, @sync)
      return subject
    end

    # 🔴 **既定は見るだけ**（#614）。
    def test_follow_sync_previews
      out, _, exited = run_command {sync_command([Set['3'], Set['4', '5']]).follow_sync}

      assert_false(exited)
      assert_match("follow: 1 3\nunfollow: 2 4 5\nlimit: ", out)
      assert_nil(@sync.forced)
    end

    # 🔴 **`--apply` は歯止めを外して 1 回だけ通す**（#614）。
    def test_follow_sync_applies_with_force
      out, = run_command {sync_command([Set['3'], Set['4', '5']], {apply: true}).follow_sync}

      assert_equal("followed: 1 unfollowed: 2\n", out)
      assert_true(@sync.forced)
    end

    def test_follow_sync_without_followers
      _, err, exited = run_command {sync_command(nil).follow_sync}

      assert_true(exited)
      assert_match('フォロワーの一覧を引けませんでした', err)
    end
  end
end
