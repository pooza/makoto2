require 'tmpdir'

module Makoto
  # 起動時に読み込んだリビジョン（#242）。
  class PackageTest < TestCase
    # 🔴 **チェックアウトの短縮 SHA。**⚠ **CI も `actions/checkout` なので `.git` がある。**
    def test_revision_is_a_short_sha
      assert_match(/\A\h{7,}\z/, Package.read_revision(Environment.dir))
    end

    # ⚠⚠ **プロセスの中で固定する**（作業木が進んでも、動いているものは変わらない）。
    def test_revision_is_read_once
      assert_same(Package.revision, Package.revision)
    end

    # ⚠ **チェックアウトでない置き方でも落ちない。**
    def test_revision_outside_a_checkout_is_nil
      Dir.mktmpdir do |dir|
        assert_nil(Package.read_revision(dir))
      end
    end
  end
end
