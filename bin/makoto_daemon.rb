#!/usr/bin/env ruby

$LOAD_PATH.unshift(File.join(File.expand_path('..', __dir__), 'app/lib'))
ENV['RAKE'] = nil

# daemon(8) 由来の無リーダー pipe に書き込んで Errno::EPIPE で死ぬのを避ける。
# モロヘイヤ / cure-api で実際に踏んだ、例外が一切ログに残らなくなる構造。
#
# 常駐する start / restart のときだけ塞ぐ。stop / status まで塞ぐと、パイプや
# スクリプト経由で叩いたときに結果が黙って消える（監視から使うので困る）。
if ['start', 'restart'].include?(ARGV.first)
  $stdin.reopen(File::NULL, 'r') unless $stdin.tty?
  [$stdout, $stderr].each do |io|
    io.reopen(File::NULL, 'w') unless io.tty?
  end
end

require 'makoto'
module Makoto
  MakotoDaemon.spawn!
end
