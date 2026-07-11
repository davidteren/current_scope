require "test_helper"

class ReportTest < ActiveSupport::TestCase
  test "title is required" do
    report = Report.new(title: "", project: projects(:one), requested_by: users(:one))
    assert_not report.valid?
    assert_includes report.errors[:title], "can't be blank"
  end

  test "title is capped at 200 characters" do
    report = Report.new(title: "x" * 201, project: projects(:one), requested_by: users(:one))
    assert_not report.valid?
    assert_includes report.errors[:title], "is too long (maximum is 200 characters)"
  end
end
