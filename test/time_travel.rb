module Makoto
  class TimeTravelTest < TestCase
    setup do
      @env = ENV.to_h.slice(TimeTravel::START_KEY, TimeTravel::SCALE_KEY)
      TimeTravel.reset!
    end

    teardown do
      [TimeTravel::START_KEY, TimeTravel::SCALE_KEY].each {|key| ENV.delete(key)}
      @env.each {|key, value| ENV[key] = value}
      TimeTravel.reset!
      config['/mastodon/url'] = @url if @url
    end

    # ⚠ **`activate!` は `Environment.test?` で何もしない**（テスト中に時刻を
    # 動かすと固定時刻の期待値が壊れる）ので、⚠⚠ **判定の部品を直接見る。**
    def with_env(start: nil, scale: nil)
      ENV[TimeTravel::START_KEY] = start
      ENV[TimeTravel::SCALE_KEY] = scale
      TimeTravel.reset!
      yield
    end

    def with_mastodon(url)
      @url ||= config['/mastodon/url']
      config['/mastodon/url'] = url
      yield
    end

    def test_does_nothing_without_the_start_key
      with_env(start: nil) do
        assert_false(TimeTravel.requested?)
        assert_nil(TimeTravel.activate!)
        assert_false(TimeTravel.active?)
      end
    end

    def test_requested_with_the_start_key
      with_env(start: '2026-11-04 11:55:00 +0900') do
        assert_true(TimeTravel.requested?)
      end
    end

    def test_start_time
      with_env(start: '2026-11-04 11:55:00 +0900') do
        assert_equal(Time.parse('2026-11-04 11:55:00 +0900'), TimeTravel.start_time)
      end
    end

    # ⚠ **既定値に逃がさない。**書き間違いが「いまの時刻で普通に動く」に化けると、
    # ⚠⚠ **リハーサルのつもりで何も検証していない状態になる。**
    def test_a_broken_start_time_raises
      with_env(start: 'いつか') do
        assert_raise(Ginseng::ConfigError) {TimeTravel.start_time}
      end
    end

    def test_scale_defaults_to_one
      with_env(start: '2026-11-04 11:55:00 +0900') do
        assert_equal(1, TimeTravel.scale)
      end
    end

    def test_scale
      with_env(start: '2026-11-04 11:55:00 +0900', scale: '10') do
        assert_equal(10, TimeTravel.scale)
      end
    end

    # ⚠⚠ **上限を超える倍率は落とす。**⚠ **投稿 1 本が `tolerance` を食い尽くし、
    # 「枠を跨ぐ」状態を人工的に作ってしまう**（→ `TimeTravel` 冒頭の表）。
    def test_too_large_a_scale_raises
      with_env(start: '2026-11-04 11:55:00 +0900', scale: (TimeTravel::MAX_SCALE + 1).to_s) do
        assert_raise(Ginseng::ConfigError) {TimeTravel.scale}
      end
    end

    def test_a_broken_scale_raises
      with_env(start: '2026-11-04 11:55:00 +0900', scale: '0') do
        assert_raise(Ginseng::ConfigError) {TimeTravel.scale}
      end
    end

    # 🔴 **これが本体。**⚠⚠ **知っている投稿先にしか出さない**（fail-closed）。
    def test_an_unknown_mastodon_host_is_refused
      with_mastodon('https://precure.ml') do
        assert_raise(Ginseng::ConfigError) {TimeTravel.verify!}
      end
    end

    def test_an_allowed_mastodon_host_passes
      with_mastodon("https://#{TimeTravel::ALLOWED_HOSTS.first}") do
        assert_true(TimeTravel.verify!)
      end
    end

    # ⚠ **投稿先が読めないときも通さない**（設定が壊れている状態で騙さない）。
    def test_a_broken_mastodon_url_is_refused
      with_mastodon('') do
        assert_raise(Ginseng::ConfigError) {TimeTravel.verify!}
      end
    end

    # ⚠ **`environment` は表示以外に何も変えない値**だが、⚠⚠ **本番と名乗って
    # いる箱では無条件に落とす**（判定を 2 つ持つ）。
    def test_production_is_refused_even_with_an_allowed_host
      with_mastodon("https://#{TimeTravel::ALLOWED_HOSTS.first}") do
        Environment.define_singleton_method(:production?) {true}

        assert_raise(Ginseng::ConfigError) {TimeTravel.verify!}
      ensure
        Environment.singleton_class.remove_method(:production?)
      end
    end

    def test_describe
      with_env(start: '2026-11-04 11:55:00 +0900', scale: '10') do
        with_mastodon("https://#{TimeTravel::ALLOWED_HOSTS.first}") do
          described = TimeTravel.describe

          assert_equal(10, described[:scale])
          assert_equal(TimeTravel::ALLOWED_HOSTS.first, described[:mastodon])
          assert_include(described[:start], '2026-11-04')
        end
      end
    end
  end
end
