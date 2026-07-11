require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  test "name is required" do
    project = Project.new(name: "")
    assert_not project.valid?
    assert_includes project.errors[:name], "can't be blank"
  end

  test "name is capped at 120 characters" do
    project = Project.new(name: "x" * 121)
    assert_not project.valid?
    assert_includes project.errors[:name], "is too long (maximum is 120 characters)"
  end
end
