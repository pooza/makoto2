module Makoto
  # 🔴 **公開してよい曲の URL**（#283）。⚠⚠ **`track.url` は曲紹介が 1 日 3 回、永久に公開する URL**で、
  # **Mastodon はプレビューカードのために取りに行く。**⚠ **収集は月 1 回の定常の経路**（#294）なので、
  # **上流の形が変わったら黙って公開せずに落とす。**
  #
  # ⚠ **使うのは 3 か所**: 取り込み（`TrackImporter#sanitize_urls`）・公開する直前（`TrackRepository#linkable`
  # ・#355）・手で書く MV の表（`MusicVideos`・#498）。🔴 **線を 1 か所に置く**（写すと片方だけ動く）。
  module TrackUrl
    HOSTS = ['music.apple.com'].freeze

    # 許可したホストの https か。
    #
    # 🔴 **`linkable`（`https://<host>/` の前方一致）と同じ強さにする**（#558）。⚠ `URI#host` だけを
    # 見ると、userinfo つき（`https://x:y@music.apple.com/a`）やポートつき
    # （`https://music.apple.com:8080/a`）も通ってしまう。
    def self.public?(value)
      value = value.to_s
      uri = URI.parse(value)
      return false unless uri.is_a?(URI::HTTPS)
      return false unless uri.userinfo.nil?
      return HOSTS.include?(uri.host) && value.start_with?(prefix(uri.host))
    rescue URI::InvalidURIError
      return false
    end

    # 🔴 **`TrackRepository#linkable` が SQL の前方一致に使う形と同じ**。
    def self.prefix(host)
      return "https://#{host}/"
    end
  end
end
