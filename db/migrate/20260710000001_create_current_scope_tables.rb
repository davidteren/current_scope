class CreateCurrentScopeTables < ActiveRecord::Migration[7.1]
  def change
    create_table :current_scope_roles do |t|
      t.string :name, null: false, index: { unique: true }
      t.boolean :full_access, null: false, default: false
      t.timestamps
    end

    create_table :current_scope_role_permissions do |t|
      t.references :role, null: false, foreign_key: { to_table: :current_scope_roles }
      t.string :permission_key, null: false
      t.index [ :role_id, :permission_key ], unique: true
    end

    create_table :current_scope_role_assignments do |t|
      t.references :subject, polymorphic: true, null: false,
                   index: { unique: true, name: "index_current_scope_one_role_per_subject" }
      t.references :role, null: false, foreign_key: { to_table: :current_scope_roles }
      t.timestamps
    end

    create_table :current_scope_scoped_role_assignments do |t|
      t.references :subject, polymorphic: true, null: false
      t.references :role, null: false, foreign_key: { to_table: :current_scope_roles }
      t.references :resource, polymorphic: true, null: false
      t.timestamps
      t.index [ :subject_type, :subject_id, :resource_type, :resource_id, :role_id ],
              unique: true, name: "index_current_scope_unique_scoped_assignment"
    end
  end
end
