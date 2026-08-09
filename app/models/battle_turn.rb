class BattleTurn < ApplicationRecord
  belongs_to :battle
  belongs_to :attacker, class_name: "Character"
  belongs_to :defender, class_name: "Character"

  # A commitment by either player is worth pushing to both browsers so the
  # "opponent is ready" indicator updates live.
  broadcasts_refreshes_to ->(turn) { turn.battle }

  def fired?
    aim_x.present?
  end

  def moved?
    !move_delta.nil?
  end

  def ready?
    fired? && moved?
  end

  def resolved?
    resolved_at.present?
  end

  # Everything the browser needs to replay this round. Safe to expose to both
  # players because a resolved round has no secrets left.
  def animation_payload(battle)
    {
      id: id,
      turnNumber: turn_number,
      attackerSide: battle.side_of(attacker),
      attackerPosition: attacker_position,
      aimX: aim_x.to_f,
      defenderFrom: defender_position_before,
      defenderTo: defender_position_after,
      distance: distance.to_f,
      hit: hit,
      damage: damage,
      hpBefore: defender_hp_before,
      hpAfter: defender_hp_after
    }
  end
end
