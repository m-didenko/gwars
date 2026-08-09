class CreateBattles < ActiveRecord::Migration[7.1]
  def change
    create_table :battles do |t|
      t.integer :player_one_id
      t.integer :player_two_id
      t.integer :current_turn_id
      t.integer :winner_id
      t.integer :status

      t.timestamps
    end
    add_index :battles, :player_one_id
    add_index :battles, :player_two_id
  end
end
