class Battle < ApplicationRecord
  broadcasts_refreshes

  belongs_to :player_one, class_name: "Character"
  belongs_to :player_two, class_name: "Character"
  belongs_to :current_turn, class_name: "Character", optional: true
  belongs_to :winner, class_name: "Character", optional: true

  has_many :battle_actions, dependent: :destroy

  enum :status, { pending: 0, active: 1, finished: 2 }

  validates :player_two_id, uniqueness: {
    scope: :player_one_id, message: "battle with this opponent already exists"
  }, if: -> { pending? || active? }

  # The player who wasn't challenged accepts the fight; the challenger (player_one) moves first.
  def accept!
    raise "Battle already started" unless pending?

    update!(status: :active, current_turn: player_one)
  end

  def participant?(character)
    character.id.in?([player_one_id, player_two_id])
  end

  def opponent_of(character)
    character.id == player_one_id ? player_two : player_one
  end

  # Core combat resolution: attacker deals damage to the other participant,
  # switches turn (or ends the battle if the defender's HP drops to 0).
  def attack!(attacker)
    raise "Battle is not active" unless active?
    raise "Not this character's turn" unless current_turn_id == attacker.id
    raise "#{attacker.name} is not part of this battle" unless participant?(attacker)

    defender = opponent_of(attacker)
    damage = [attacker.attack - defender.defense + rand(-2..2), 1].max

    defender.update!(hp: [defender.hp - damage, 0].max)

    action = battle_actions.create!(
      character: attacker,
      action_type: :attack,
      damage: damage,
      target_hp_after: defender.hp
    )

    if defender.hp.zero?
      update!(status: :finished, winner: attacker, current_turn: nil)
    else
      update!(current_turn: defender)
    end

    action
  end
end
