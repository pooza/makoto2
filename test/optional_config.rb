module Makoto
  # ⚠⚠ **「設定を消せば止まる／元の挙動に戻る」と説明した設定を、実際に消して確かめる。**
  #
  # ⚠ **`Config#[]` はキーが無ければ例外を上げる**ので、素の `config[]` で読んでいると
  # **消した瞬間に落ちる**（0.2.0 のリリース前レビューで実測・#77）。
  # ⚠⚠ **しかも `rake config:lint` は通る**（schema が必須にしていないため）ので、
  # **その設定を使う瞬間まで分からない。**
  #
  # ⚠ **既存のテストは「キーはあるが空」しか見ていなかった**（`test/setlist.rb` の
  # `test_excludes_nothing_without_the_setting`）。**本物の「無い」を見るのがここ。**
  class OptionalConfigTest < TestCase
    # ⚠ 消してよい設定（schema が必須にしていないもの）。
    OPTIONAL_KEYS = [
      '/live/hashtag',
      '/live/setlist/cover_prefix',
      '/live/setlist/cover_solo_weight',
      '/live/setlist/exclude/collections',
      '/live/setlist/exclude/tracks',
      '/live/mc/hinge',
    ].freeze

    def date
      return Date.new(2026, 11, 4)
    end

    def drop(*keys)
      keys.each {|key| config.delete(key)}
      return nil
    end

    # ⚠ cure-api は引けても引けなくてもよい（ここで見たいのは設定の欠落）。
    # ⚠⚠ **実サーバーへは飛ばさない**ので、辞書を返す偽物を渡す。
    def cure_api
      return Struct.new(:x) do
        def available? = true
        def singer?(_name) = true
      end.new(nil)
    end

    # ⚠ 前提の確認。**消す前に本当に在ること**を見ておかないと、以下のテストが
    # 「元から無いキーを消した」だけになって素通しする。
    def test_optional_keys_exist_by_default
      OPTIONAL_KEYS.each {|key| assert_true(config.key?(key), key)}
    end

    # ⚠⚠ **消しても `rake config:lint` は通る。**schema が必須にしていないので、
    # **設定の側では止められない**。だからコードの側が耐える必要がある。
    def test_config_lint_passes_without_them
      drop(*OPTIONAL_KEYS)

      assert_empty(config.errors)
    end

    # ⚠⚠ **`/live/hashtag` を消すと常駐が起動しなくなっていた。**
    # ⚠ `Live#jobs` は `MakotoDaemon#register_jobs` から呼ばれ、例外は `start` を落とす。
    def test_jobs_are_built_without_a_hashtag
      drop('/live/hashtag')
      jobs = Live.new(repository: MessageRepository.new(corpus_db)).jobs

      assert_equal(4, jobs.size)
    end

    # ⚠ タグが無ければ本文だけが出る（付け忘れではなく「付けない」）。
    def test_hashtag_is_not_appended_when_the_setting_is_gone
      drop('/live/hashtag')
      source = Live.new(repository: MessageRepository.new(corpus_db)).tagged(->(_time) {'本文'})

      assert_equal('本文', source.call(Time.now))
    end

    # ⚠⚠ **`exclude` を消すと 8 時間 160 枠が 1 本も出なくなっていた。**
    # ⚠ 例外は `PostingJob#create_text` の rescue に飲まれるので、
    # **「登録ジョブ 5 で健全」のまま沈黙する**（→ #78）。
    def test_setlist_is_built_without_the_exclude_setting
      drop('/live/setlist/exclude/collections', '/live/setlist/exclude/tracks')
      list = Setlist.new(date: date, slots: 20, repository: TrackRepository.new(track_db),
        cure_api: cure_api)

      assert_equal(20, list.entries.size)
    end

    # ⚠ 重みを消せば一様抽選に戻る（コメントが謳っていた挙動）。
    def test_setlist_is_built_without_the_solo_weight
      drop('/live/setlist/cover_solo_weight')
      list = Setlist.new(date: date, slots: 20, repository: TrackRepository.new(track_db),
        cure_api: cure_api)

      assert_equal(20, list.entries.size)
    end

    # ⚠⚠ **schema が「必須にしない — 引けなければ通常の割合で引く」と書いていたのに、
    # キーが無いと落ちていた**（#73 で足した行）。**書いたとおりに動くこと。**
    def test_script_index_falls_back_without_the_hinge_setting
      drop('/live/mc/hinge')
      entry = Setlist::Entry.new(kind: :mc, ordinal: 13, mc_total: 26, mc_hinge: 13)
      scripts = Array.new(26) {|i| {slug: "s#{i}", body: "MC #{i}"}}
      program = Live.new(repository: MessageRepository.new(corpus_db)).program

      assert_equal(13, program.script_index(entry, scripts))
    end

    # ⚠ カバーの断りを消しても曲の本文は組める。
    def test_cover_prefix_is_optional
      drop('/live/setlist/cover_prefix')
      program = Live.new(repository: MessageRepository.new(corpus_db)).program

      assert_nil(program.cover_prefix)
    end

    # ⚠⚠ **値の側の失敗までは握り潰さない。**キーの有無だけを見る形なので、
    # **設定パスの typo は今までどおり例外になる**（fail-open な rescue にしない）。
    def test_a_typo_still_raises
      assert_raise(Ginseng::ConfigError) {config['/live/setlisto/opening']}
    end
  end
end
