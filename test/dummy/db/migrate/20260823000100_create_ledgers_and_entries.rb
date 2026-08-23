class CreateLedgersAndEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :ledgers do |t|
      t.string :code, null: false
      t.string :name, null: false
      t.timestamps
    end
    add_index :ledgers, :code, unique: true

    create_table :entries do |t|
      t.string :ledger_id
      t.string :title, null: false
      t.timestamps
    end
    add_index :entries, :ledger_id
  end
end
