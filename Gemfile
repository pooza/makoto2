source 'https://rubygems.org'
ruby '>= 4.0', '< 5.0'
gem 'ginseng-core', github: 'pooza/ginseng-core', branch: 'main', require: 'ginseng'
gem 'ginseng-fediverse', github: 'pooza/ginseng-fediverse', branch: 'main',
  require: 'ginseng/fediverse'
gem 'rufus-scheduler'
gem 'sequel'
# rufus-scheduler の依存として入るが、Timetable が直接使うので明示する。
gem 'tzinfo'
gem 'sqlite3'
# 監視の口（MonitorServer）を常駐の中で起こすためだけに使う（#84）。
# ⚠ WebUI ではない。⚠⚠ 管理コンソールは作らないという決定は変えていない。
gem 'puma'
gem 'thor'
# リハーサルで日付だけを騙すために使う（#110）。⚠⚠ **本番の group に置く。**
# ⚠ `bydo` と `rubicon` で gem 構成が違うと、それ自体が「日付以外は全く同じ」を崩す。
# 🔴 発動は環境変数で、投稿先が allowlist に無ければ起動時に落ちる（→ TimeTravel）。
gem 'timecop'

group :development do
  # 依存の脆弱性スキャン（#104）。⚠ **外部の advisory DB を引く**ので、
  # ⚠⚠ **`test.yml` には載せない** — **コードを 1 行も触っていないのに、DB が
  # 更新された日に緑が赤へ変わる**（→ `.github/workflows/audit.yml`）。
  gem 'bundler-audit', require: false
  gem 'ginseng-style', github: 'pooza/ginseng-style', tag: 'v1.1.4', require: false
  gem 'rubocop-sequel'
  gem 'test-unit'
  gem 'webmock'
end
