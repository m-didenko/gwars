class CreateBattleActions < ActiveRecord::Migration[7.1]
  def change
    create_table :battle_actions do |t|
      t.references :battle, null: false, foreign_key: true
      t.references :character, null: false, foreign_key: true
      t.integer :action_type
      t.integer :damage
      t.integer :target_hp_after

      t.timestamps
    end
  end
end
