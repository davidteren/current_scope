class CreatePayRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :pay_runs do |t|
      t.string :period, null: false
      t.string :label, null: false
      t.decimal :amount, precision: 12, scale: 2
      t.string :status, null: false, default: "pending"
      t.references :prepared_by, null: false, foreign_key: { to_table: :users }
      t.references :approved_by, foreign_key: { to_table: :users }
      t.datetime :approved_at

      t.timestamps
    end
  end
end
