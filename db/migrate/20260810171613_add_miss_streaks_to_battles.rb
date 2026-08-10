class AddMissStreaksToBattles < ActiveRecord::Migration[7.1]
  def change
    add_column :battles, :player_one_miss_streak, :integer, default: 0, null: false
    add_column :battles, :player_two_miss_streak, :integer, default: 0, null: false
  end
end
