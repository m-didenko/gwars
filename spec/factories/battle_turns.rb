FactoryBot.define do
  factory :battle_turn do
    association :battle
    turn_number { 1 }
    attacker { battle.player_one }
    defender { battle.player_two }
    attacker_position { 20 }
    deadline_at { 30.seconds.from_now }
  end
end
