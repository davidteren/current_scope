require "test_helper"

# Substring checks stay green when a printed line or a blank separator
# disappears. These two strings are the whole report, so a missing line fails.
module ReportPrinterFixture
  class Invoice
  end

  Denial = Struct.new(
    :subject_gid, :permission, :target_gid, :denials, :record_less, :model,
    keyword_init: true
  )

  class Grant
    def initialize(subject_id:, role_name:)
      @subject_id = subject_id
      @role_name = role_name
    end

    def current_scope_resolved_record(_which)
      Struct.new(:name).new("Ada Lovelace")
    end

    def subject_type = "User"
    def subject_id = @subject_id
    def role = Struct.new(:name).new(@role_name)
    def resource_type = "Project"
    def resource_id = 9
  end
end

class ReportPrinterTest < ActiveSupport::TestCase
  setup do
    @config = CurrentScope.config
    @saved_sod = @config.sod_actions
    @saved_enforcement = @config.enforcement
    @saved_audit = @config.audit
    @config.sod_actions = [ "approve" ]
    @config.enforcement = :report
    @config.audit = true
  end

  teardown do
    @config.sod_actions = @saved_sod
    @config.enforcement = @saved_enforcement
    @config.audit = @saved_audit
  end

  test "a populated report prints every section and every blank separator" do
    text, err = capture_stderr { rich_printer.to_s }

    assert_equal file_fixture("report_printer_rich.txt").read, text
    assert_equal file_fixture("report_printer_rich_stderr.txt").read, err
  end

  test "a moot-only report prints the empty ledger and the incomplete preflight" do
    text, err = capture_stderr { moot_printer.to_s }

    assert_equal file_fixture("report_printer_moot.txt").read, text
    assert_equal "", err
  end

  private

  def capture_stderr
    previous = $stderr
    $stderr = StringIO.new
    [ yield, $stderr.string ]
  ensure
    $stderr = previous
  end

  def denial(gid, permission, denials, model:, target: "gid://current-scope/Project/9", record_less: false)
    ReportPrinterFixture::Denial.new(
      subject_gid: gid, permission: permission, target_gid: target,
      denials: denials, record_less: record_less, model: model
    )
  end

  def rich_printer
    gid = "gid://current-scope/Person/1"
    CurrentScope::ReportPrinter.new(
      rows: rich_rows(gid),
      blind_rows: blind_rows,
      initiator_rows: initiator_rows,
      preflight: CurrentScope::SodPreflight::Result.new(rows: [], inspected: 4, in_scope: 4, skipped: []),
      preflight_rows: [ [ "invoices#approve", ReportPrinterFixture::Invoice ] ],
      outstanding: [ denial(gid, "reports#show", 4, model: "Report") ],
      resolved: [ denial(gid, "reports#edit", 3, model: "Report") ],
      unknown: unknown_denials(gid),
      moot: [ denial("gid://current-scope/Missing/1", "reports#destroy", 5, model: "Report") ],
      legacy_model: [ denial(gid, "reports#show", 1, model: :absent) ],
      dead_model: [ denial(gid, "reports#index", 2, model: "Gone") ],
      superseded: [ denial(gid, "reports#update", 6, model: "Report") ],
      dead_grants: dead_grants,
      untargeted_grants: [ ReportPrinterFixture::Grant.new(subject_id: 12, role_name: "Witness") ],
      nonconforming_grants: [ ReportPrinterFixture::Grant.new(subject_id: 11, role_name: "Auditor") ],
      unjudgeable_grants: 2
    )
  end

  def moot_printer
    skipped = [ [ "ReportsController", NameError.new("missing") ] ]
    CurrentScope::ReportPrinter.new(
      rows: [],
      blind_rows: [],
      initiator_rows: [],
      preflight: CurrentScope::SodPreflight::Result.new(
        rows: [], inspected: 0, in_scope: 3, skipped: skipped
      ),
      preflight_rows: [],
      outstanding: [],
      resolved: [],
      unknown: [],
      moot: [ denial("gid://current-scope/Missing/1", "reports#destroy", 5, model: "Report") ],
      legacy_model: [],
      dead_model: [],
      superseded: [],
      dead_grants: [],
      untargeted_grants: [],
      nonconforming_grants: [],
      unjudgeable_grants: 1
    )
  end

  def rich_rows(gid)
    target = "gid://current-scope/Project/9"
    [
      [ gid, "Ada Lovelace", { "permission" => "reports#show", "record_less" => false, "model" => "Report" }, target ],
      [ gid, "Ada Lovelace", { "permission" => "reports#index", "record_less" => false, "model" => "Gone" }, target ],
      [ gid, "Ada Lovelace", "not-a-hash", "gid://current-scope/Target/1" ]
    ]
  end

  def unknown_denials(gid)
    [
      denial(gid, "reports#index", 2, model: "Gone"),
      denial(gid, nil, 1, model: :absent, target: "gid://current-scope/Target/1", record_less: nil)
    ]
  end

  def blind_rows
    [
      [ "gid://current-scope/Person/2", "Grace Hopper", { "permission" => "reports#approve" }, nil ],
      [ "gid://current-scope/Person/2", "Grace Hopper", "not-a-hash", nil ]
    ]
  end

  def initiator_rows
    [
      [ "gid://current-scope/Person/3", "Cy", { "permission" => "invoices#approve", "model" => "Invoice" }, nil ]
    ]
  end

  def dead_grants
    [
      [ ReportPrinterFixture::Grant.new(subject_id: 7, role_name: "Editor"), :no_permissions ],
      [ ReportPrinterFixture::Grant.new(subject_id: 8, role_name: "Reader"), :unrouted_permissions ]
    ]
  end
end
