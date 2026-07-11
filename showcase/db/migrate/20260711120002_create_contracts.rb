class CreateContracts < ActiveRecord::Migration[8.1]
  def change
    create_table :contracts do |t|
      t.string :title, null: false
      t.string :counterparty
      t.decimal :amount, precision: 12, scale: 2
      t.string :status, null: false, default: "pending"
      t.references :raised_by, null: false, foreign_key: { to_table: :users }
      t.references :approved_by, foreign_key: { to_table: :users }
      t.datetime :approved_at

      t.timestamps
    end
  end
end
