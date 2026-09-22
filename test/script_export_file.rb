require 'tmpdir'

module Makoto
  # 原稿の書き出し先（#273）。🔴 **public な作業ツリーの中へは書かない・0600 で書く。**
  class ScriptExportFileTest < TestCase
    def setup
      super
      @dir = Dir.mktmpdir('makoto-export')
    end

    def teardown
      FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
      super
    end

    def path
      return File.join(@dir, 'morning.yaml')
    end

    def test_refuses_the_working_tree
      assert_raise(Ginseng::ValidateError) {ScriptExportFile.new(File.join(Environment.dir, 'morning.yaml'))}
    end

    # ⚠ **`../` を落とした形も、相対のまま渡ってくる。**
    def test_refuses_a_relative_path_inside_the_working_tree
      Dir.chdir(Environment.dir) do
        assert_raise(Ginseng::ValidateError) {ScriptExportFile.new('morning.yaml')}
      end
    end

    # ⚠⚠ **リンクを経由しても同じ**（`File.expand_path` だけでは素通りする）。
    def test_refuses_the_working_tree_through_a_link
      link = File.join(@dir, 'repo')
      File.symlink(Environment.dir, link)

      assert_raise(Ginseng::ValidateError) {ScriptExportFile.new(File.join(link, 'morning.yaml'))}
    end

    # ⚠ **名前が前方一致するだけの隣のディレクトリは拒まない**（`makoto2-scripts` など）。
    def test_accepts_a_sibling_with_the_same_prefix
      sibling = "#{File.realpath(Environment.dir)}-export-test"
      FileUtils.mkdir_p(sibling)
      file = ScriptExportFile.new(File.join(sibling, 'morning.yaml'))

      assert_equal(File.join(sibling, 'morning.yaml'), file.path)
    ensure
      FileUtils.remove_entry(sibling) if sibling && File.exist?(sibling)
    end

    def test_writes_a_private_file
      ScriptExportFile.new(path).write('原稿')

      assert_equal('原稿', File.read(path))
      assert_equal(0o600, File.stat(path).mode & 0o777)
    end

    # ⚠⚠ **既にあるものは `force` が無ければ触らない**（存在の確認と作成が 1 手）。
    def test_refuses_to_overwrite_without_force
      File.write(path, '先にあるもの')

      assert_raise(Errno::EEXIST) {ScriptExportFile.new(path).write('原稿')}
      assert_equal('先にあるもの', File.read(path))
    end

    # 🔴 **`force` の上書きでも、先にあった緩い mode を残さない。**
    def test_tightens_an_overwritten_file
      File.write(path, '先にあるもの')
      File.chmod(0o644, path)
      ScriptExportFile.new(path, force: true).write('原稿')

      assert_equal('原稿', File.read(path))
      assert_equal(0o600, File.stat(path).mode & 0o777)
    end

    # ⚠ **行き先の無いリンクを辿って作らない。**
    def test_does_not_follow_a_dangling_link
      target = File.join(@dir, 'elsewhere.yaml')
      File.symlink(target, path)

      assert_raise(Errno::ELOOP) {ScriptExportFile.new(path, force: true).write('原稿')}
      assert_false(File.exist?(target))
    end
  end
end
