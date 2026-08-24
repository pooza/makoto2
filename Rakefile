$LOAD_PATH.unshift(File.join(File.expand_path(__dir__), 'app/lib'))
ENV['RAKE'] = 'yes'

require 'makoto'
module Makoto
  Sequel.connect(Environment.dsn)
  load_tasks
  # ⚠ **gem が配る `cert:update` / `cert:check`**（#138 / 上流 `pooza/ginseng-core#512`）。
  #
  # 🔴 **`Makoto::Environment` を渡すこと。**⚠⚠ **既定の `Ginseng::Environment` は
  # gem のルート**を指すので、**依存のチェックアウトの中へ書きに行く**（上流 `#548`）。
  #
  # ⚠ **`cert/cacert.pem` は持たない**（2026-08-24）。⚠⚠ **無ければ OS の CA ストアに
  # 倒れる**ので無害で、**持つと更新の当番が増える**（上流自身が `#515` で当番不在に
  # なっている）。🔴 **固定したくなったら `rake cert:update` を叩けばよい**という
  # 状態にしておくのがここの目的。
  Ginseng.load_tasks(environment: Environment)
end
