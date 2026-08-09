class ConvertToTankBattle < ActiveRecord::Migration[7.1]
  def change
    # The old melee log is replaced by BattleTurn, which has to hold both
    # players' hidden decisions before a round can be resolved.
    drop_table :battle_actions do |t|
      t.references :battle, null: false, foreign_key: true
      t.references :character, null: false, foreign_key: true
      t.integer :action_type
      t.integer :damage
      t.integer :target_hp_after
      t.timestamps
    end

    change_table :battles, bulk: true do |t|
      t.integer :player_one_hp
      t.integer :player_two_hp
      t.integer :player_one_position
      t.integer :player_two_position
      t.integer :attacker_id
      t.integer :turn_number, null: false, default: 0
      t.remove :current_turn_id, type: :integer
    end

    # HP is per-battle now, so a character no longer carries damage between fights.
    remove_column :characters, :hp, :integer, default: 100, null: false

    create_table :battle_turns do |t|
      t.references :battle, null: false, foreign_key: true
      t.integer :turn_number, null: false
      t.integer :attacker_id, null: false
      t.integer :defender_id, null: false
      t.integer :attacker_position, null: false

      # Both stay nil until that player commits; a round resolves once both are set.
      t.decimal :aim_x, precision: 6, scale: 2
      t.integer :move_delta

      t.integer :defender_position_before
      t.integer :defender_position_after
      t.decimal :distance, precision: 6, scale: 2
      t.boolean :hit
      t.integer :damage
      t.integer :defender_hp_before
      t.integer :defender_hp_after
      t.datetime :resolved_at

      t.timestamps
    end

    add_index :battle_turns, [:battle_id, :turn_number], unique: true
  end
end
