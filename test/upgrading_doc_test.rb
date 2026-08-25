require "test_helper"

# UPGRADING.md is the only thing standing between a host and a silent grant
# wipe on its next deploy seed (#191). These pins hold the two facts the #116
# real-host bake proved were missing: the command that migrates the TEST
# database, and the list of query forms a reader may leave alone. Both are
# asserted against the 0.4 → 0.5 section only, so the same string elsewhere in
# the file cannot satisfy them.
#
# Three files repeat the upgrade command list, and #191 exists because one of
# them was incomplete. The README callout is pinned here too, beside the
# document it summarizes; the docs-site copy is pinned in docs_site_test.rb.
class UpgradingDocTest < ActiveSupport::TestCase
  UPGRADING = File.expand_path("../UPGRADING.md", __dir__)
  README = File.expand_path("../README.md", __dir__)
  SECTION_HEADING = "## 0.4 → 0.5: run the migrations".freeze

  # The whole of #191 is that a host copies the command block and runs it. The
  # prose around the block names db:test:prepare several times, so asserting the
  # bare command name passes even when the block itself has lost the line. Pin
  # the block: all three commands, in the order they must be run.
  COMMAND_BLOCK = <<~SH
    bin/rails current_scope:install:migrations
    bin/rails db:migrate
    bin/rails db:test:prepare
  SH

  setup do
    lines = File.readlines(UPGRADING, encoding: "UTF-8")
    start = lines.index { |line| line.start_with?(SECTION_HEADING) }
    assert start, "expected a #{SECTION_HEADING.inspect} heading in UPGRADING.md"
    rest = lines[(start + 1)..] || []
    stop = rest.index { |line| line.start_with?("## ") } || rest.length
    @section = rest[0...stop].join
  end

  test "the 0.4 to 0.5 command block runs db:test:prepare after db:migrate" do
    assert_includes @section, COMMAND_BLOCK,
                    "the 0.4 → 0.5 command block must end with the command that migrates the test database"
  end

  test "the string-id subsection still clears the safe query forms" do
    assert_includes @section, "where(subject_id: user.id)",
                    "the string-id subsection must keep naming the query forms that stay safe"
  end

  test "the README upgrade callout names db:test:prepare" do
    assert_includes File.read(README, encoding: "UTF-8"), "bin/rails db:test:prepare",
                    "the README upgrade callout must name db:test:prepare, like UPGRADING.md"
  end
end
