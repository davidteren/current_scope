# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_10_171443) do
  create_table "current_scope_role_assignments", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "role_id", null: false
    t.integer "subject_id", null: false
    t.string "subject_type", null: false
    t.datetime "updated_at", null: false
    t.index ["role_id"], name: "index_current_scope_role_assignments_on_role_id"
    t.index ["subject_type", "subject_id"], name: "index_current_scope_one_role_per_subject", unique: true
  end

  create_table "current_scope_role_permissions", force: :cascade do |t|
    t.string "permission_key", null: false
    t.integer "role_id", null: false
    t.index ["role_id", "permission_key"], name: "idx_on_role_id_permission_key_5fd185cc5b", unique: true
    t.index ["role_id"], name: "index_current_scope_role_permissions_on_role_id"
  end

  create_table "current_scope_roles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "full_access", default: false, null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_current_scope_roles_on_name", unique: true
  end

  create_table "current_scope_scoped_role_assignments", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "resource_id", null: false
    t.string "resource_type", null: false
    t.integer "role_id", null: false
    t.integer "subject_id", null: false
    t.string "subject_type", null: false
    t.datetime "updated_at", null: false
    t.index ["resource_type", "resource_id"], name: "index_current_scope_scoped_role_assignments_on_resource"
    t.index ["role_id"], name: "index_current_scope_scoped_role_assignments_on_role_id"
    t.index ["subject_type", "subject_id", "resource_type", "resource_id", "role_id"], name: "index_current_scope_unique_scoped_assignment", unique: true
    t.index ["subject_type", "subject_id"], name: "index_current_scope_scoped_role_assignments_on_subject"
  end

  create_table "projects", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.datetime "updated_at", null: false
  end

  create_table "reports", force: :cascade do |t|
    t.datetime "approved_at"
    t.integer "approved_by_id"
    t.datetime "created_at", null: false
    t.integer "project_id", null: false
    t.integer "requested_by_id", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["approved_by_id"], name: "index_reports_on_approved_by_id"
    t.index ["project_id"], name: "index_reports_on_project_id"
    t.index ["requested_by_id"], name: "index_reports_on_requested_by_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "current_scope_role_assignments", "current_scope_roles", column: "role_id"
  add_foreign_key "current_scope_role_permissions", "current_scope_roles", column: "role_id"
  add_foreign_key "current_scope_scoped_role_assignments", "current_scope_roles", column: "role_id"
  add_foreign_key "reports", "projects"
  add_foreign_key "reports", "users", column: "approved_by_id"
  add_foreign_key "reports", "users", column: "requested_by_id"
  add_foreign_key "sessions", "users"
end
