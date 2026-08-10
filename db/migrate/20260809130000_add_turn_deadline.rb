class AddTurnDeadline < ActiveRecord::Migration[7.1]
  def change
    # When this turn stops accepting decisions. Nullable on purpose: a turn
    # opened before this migration has no deadline and simply never expires.
    add_column :battle_turns, :deadline_at, :datetime

    # A missing decision is not the same as a deliberate one — the defender who
    # ran out of time and the defender who chose to hold still both end up with
    # move_delta 0, and only these flags tell them apart afterwards.
    add_column :battle_turns, :attacker_timed_out, :boolean, default: false, null: false
    add_column :battle_turns, :defender_timed_out, :boolean, default: false, null: false
  end
end
