class CreateDummyTables < ActiveRecord::Migration[7.1]
  def change
    create_table :users do |t|
      t.string :name, null: false
      t.timestamps
    end

    create_table :projects do |t|
      t.string :name, null: false
      t.timestamps
    end

    create_table :reports do |t|
      t.string :title, null: false
      t.references :project, foreign_key: true
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end
  end
end
