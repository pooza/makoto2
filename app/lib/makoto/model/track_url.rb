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
    def self.public?(value)
      uri = URI.parse(value.to_s)
      return uri.is_a?(URI::HTTPS) && HOSTS.include?(uri.host)
    rescue URI::InvalidURIError
      return false
    end
  end
end
