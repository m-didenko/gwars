class BattleAction < ApplicationRecord
  belongs_to :battle
  belongs_to :character

  enum :action_type, { attack: 0, defend: 1 }
end
