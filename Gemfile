source 'https://rubygems.org'
# 下限: 実機（bydo / rubicon）と CI の Ruby が 4.0 系（4.0.6・YJIT 有効）。
# ⚠ 上限: メジャーは非互換が入りうるので、実機に入っていない系列で走らせない。
#   ⚠⚠ 事故が理由の pin ではない。外すのは「実機と CI の Ruby を 5.x にし、
#   当日通しリハーサルを 5.x で通した」とき（→ docs/CLAUDE.md の当日通し）。
ruby '>= 4.0', '< 5.0'
gem 'ginseng-core', github: 'pooza/ginseng-core', tag: 'v1.25.0', require: 'ginseng'
gem 'ginseng-fediverse', github: 'pooza/ginseng-fediverse', tag: 'v3.1.0',
  require: 'ginseng/fediverse'
gem 'rufus-scheduler'
# 例外の集約（#28）。⚠ **DSN が無ければ初期化しない**（→ `Makoto.setup_sentry`）。
gem 'sentry-ruby'
gem 'sequel'
# rufus-scheduler の依存として入るが、Timetable が直接使うので明示する。
gem 'sqlite3'
gem 'tzinfo'
# 監視の口（MonitorServer）を常駐の中で起こすためだけに使う（#84）。
# ⚠ WebUI ではない。⚠⚠ 管理コンソールは作らないという決定は変えていない。
gem 'puma'
# addressable の依存として入るが、`PostBudget.url?` が TLD の判定に直接使うので明示する（#351）。
gem 'public_suffix'
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
  # ⚠⚠ タグではなく SHA で固定する（pooza/ginseng-style#75）。タグは付け替えられる。
  gem 'ginseng-style', github: 'pooza/ginseng-style',
    ref: '05a9e5c997082bd75bd913190e0c947fdaff082d', require: false # v1.1.13
  gem 'rubocop-sequel'
  gem 'test-unit'
  gem 'webmock'
end
