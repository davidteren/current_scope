class CreateDocuments < ActiveRecord::Migration[8.0]
  def change
    create_table :documents do |t|
      t.string :type, null: false # STI: base Document, subclass Invoice
      t.string :title, null: false
      t.timestamps
    end
  end
end
