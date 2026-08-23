require "test_helper"
require "rake"

class DefinitionsTaskTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(name: "Operator")
    @owner = CurrentScope::Role.create!(name: "Owner", full_access: true)
    @editor = CurrentScope::Role.create!(name: "Editor")
    @editor.permission_keys = [ "reports#index" ]
    @editor.save!
    @tmpdir = Dir.mktmpdir
    @file = File.join(@tmpdir, "roles.yml")
    Rake::Task.clear
    Rake::TaskManager.record_task_metadata = true
    load Rails.root.join("../../lib/tasks/current_scope_tasks.rake").expand_path
    Rake::Task.define_task(:environment)
  end

  teardown do
    Rake::Task.clear
    FileUtils.remove_entry(@tmpdir)
    ENV.delete("FILE")
    ENV.delete("SNAPSHOT")
    ENV.delete("CONFIRM")
    ENV.delete("ACTOR_ID")
  end

  def invoke(name)
    Rake::Task[name].reenable
    capture_io { Rake::Task[name].invoke }
  end

  test "export writes the file" do
    ENV["FILE"] = @file
    out, _err = invoke("current_scope:definitions:export")
    assert File.file?(@file)
    assert_match(/Wrote role definitions/, out)
    document = CurrentScope::DefinitionsDocument.parse(@file)
    assert_equal [ "Editor", "Owner" ], document.roles.map(&:name)
  end

  test "diff prints an added key" do
    ENV["FILE"] = @file
    invoke("current_scope:definitions:export")
    document = CurrentScope::DefinitionsDocument.parse(@file)
    edited = document.roles.map do |role|
      next role unless role.name == "Editor"

      role.with(permission_keys: (role.permission_keys + [ "reports#approve" ]).sort)
    end
    File.write(@file, CurrentScope::DefinitionsDocument.new(edited).to_yaml)

    out, _err = invoke("current_scope:definitions:diff")
    assert_match(/role Editor gains reports#approve/, out)
  end

  test "import without CONFIRM on a populated dummy aborts" do
    ENV["FILE"] = @file
    invoke("current_scope:definitions:export")
    document = CurrentScope::DefinitionsDocument.parse(@file)
    edited = document.roles.map do |role|
      next role unless role.name == "Editor"

      role.with(permission_keys: (role.permission_keys + [ "reports#approve" ]).sort)
    end
    File.write(@file, CurrentScope::DefinitionsDocument.new(edited).to_yaml)
    ENV["ACTOR_ID"] = @user.id.to_s

    error = assert_raises(SystemExit) { invoke("current_scope:definitions:import") }
    assert_match(/Confirm is required/, error.message)
    assert_not_includes @editor.reload.permission_keys, "reports#approve"
  end

  test "missing FILE prints usage and aborts" do
    error = assert_raises(SystemExit) { invoke("current_scope:definitions:export") }
    assert_match(/FILE is required/, error.message)
  end

  test "import with CONFIRM applies and writes a snapshot beside FILE" do
    ENV["FILE"] = @file
    invoke("current_scope:definitions:export")
    document = CurrentScope::DefinitionsDocument.parse(@file)
    edited = document.roles.map do |role|
      next role unless role.name == "Editor"

      role.with(permission_keys: (role.permission_keys + [ "reports#approve" ]).sort)
    end
    File.write(@file, CurrentScope::DefinitionsDocument.new(edited).to_yaml)
    ENV["CONFIRM"] = "1"
    ENV["ACTOR_ID"] = @user.id.to_s

    invoke("current_scope:definitions:import")
    assert_includes @editor.reload.permission_keys, "reports#approve"
    assert File.file?("#{@file}.pre.yml")
  end
end
