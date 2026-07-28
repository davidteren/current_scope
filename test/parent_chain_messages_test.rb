require "test_helper"

# U4 of plan 031 (#108). Two honesty fixes, both asserted on their TEXT so they
# cannot drift back.
#
# The message one is the sharper of the two. Before #108, a host who wanted a
# scoped grant on a parent to match had one workaround: hand the PARENT back
# from current_scope_record. That raises here, because the parent has no
# initiator hook — and the message used to name exactly two fixes, the first of
# which ("define current_scope_initiator on the parent") silently blinds the
# veto. The gem was pointing hosts at the trap.
class ParentChainMessagesTest < ActiveSupport::TestCase
  setup do
    @resolver = CurrentScope::Resolver.new
    @user = User.create!(name: "Someone")
    @project = Project.create!(name: "P7")
  end

  test "the SoD missing-initiator message names current_scope_parent as the third fix" do
    previous = CurrentScope.config.sod_actions
    CurrentScope.config.sod_actions = %w[approve]

    error = assert_raises(CurrentScope::ConfigurationError) do
      @resolver.decide(subject: @user, permission: "reports#approve", record: @project)
    end

    assert_match(/current_scope_parent on the CHILD/, error.message)
    assert_match(/measure this record's initiator, not the child's/, error.message,
                 "the message must WARN about the fix that blinds the veto, not just list it")
    # The original two fixes must survive — this widens the message, never replaces it.
    assert_match(/Define current_scope_initiator on Project/, error.message)
    assert_match(/remove "approve" from config\.sod_actions/, error.message)
  ensure
    CurrentScope.config.sod_actions = previous
  end

  test "the role editor's full_access label states the non-cascade carve-out" do
    %w[edit new].each do |view|
      label = File.read(CurrentScope::Engine.root.join("app/views/current_scope/roles/#{view}.html.erb"))

      assert_match(/Does not cascade to child records/, label,
                   "roles/#{view} still claims full_access is 'every permission, present and " \
                   "future' with no carve-out, which KTD-2 made false")
    end
  end
end
