class AddProgressionToCharacters < ActiveRecord::Migration[7.1]
  def change
    add_column :characters, :level, :integer, default: 1, null: false
    add_column :characters, :experience, :integer, default: 0, null: false
    # A fresh commander has not fought yet, so they start topped up rather
    # than at 0 waiting to regenerate into their first battle.
    add_column :characters, :life, :integer, default: 100, null: false
    add_column :characters, :life_replenished_at, :datetime
  end
end
