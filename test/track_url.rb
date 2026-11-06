module Makoto
  # 公開してよい曲の URL（#283）。
  class TrackUrlTest < TestCase
    def test_allows_the_listed_host
      assert_true(TrackUrl.public?('https://music.apple.com/jp/music-video/test/1312882764?uo=4'))
    end

    def test_rejects_other_hosts_and_schemes
      assert_false(TrackUrl.public?('https://example.test/a'))
      assert_false(TrackUrl.public?('http://music.apple.com/a'))
      assert_false(TrackUrl.public?('https://music.apple.com.example.test/a'))
      assert_false(TrackUrl.public?(nil))
      assert_false(TrackUrl.public?('https://music.apple.com/a b'))
    end

    # 🔴 **`linkable` の前方一致と同じ線**（#558）。⚠ `URI#host` だけでは userinfo・port が通る。
    def test_rejects_userinfo_and_port
      assert_false(TrackUrl.public?('https://x:y@music.apple.com/a'))
      assert_false(TrackUrl.public?('https://music.apple.com:8080/a'))
      assert_false(TrackUrl.public?('https://music.apple.com:443/a'))
      assert_false(TrackUrl.public?('https://music.apple.com'))
    end
  end
end
