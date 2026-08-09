class CreateCharacters < ActiveRecord::Migration[7.1]
  def change
    create_table :characters do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name
      t.integer :hp, default: 100, null: false
      t.integer :max_hp, default: 100, null: false
      t.integer :attack, default: 10, null: false
      t.integer :defense, default: 2, null: false
      t.integer :gold, default: 0, null: false

      t.timestamps
    end
  end
end
