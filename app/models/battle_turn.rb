class BattleTurn < ApplicationRecord
  belongs_to :battle
  belongs_to :attacker, class_name: "Character"
  belongs_to :defender, class_name: "Character"

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

  # A turn opened before deadlines existed has none, and never expires.
  def expired?
    deadline_at.present? && Time.current >= deadline_at
  end

  def seconds_left
    return nil if deadline_at.nil?

    [deadline_at - Time.current, 0].max.round(1)
  end

  # Everything the browser needs to replay this round. Safe to expose to both
  # players because a resolved round has no secrets left.
  def animation_payload(battle)
    {
      id: id,
      turnNumber: turn_number,
      attackerSide: battle.side_of(attacker),
      attackerPosition: attacker_position,
      # nil when the attacker ran out of time: there is no shell to animate.
      aimX: aim_x&.to_f,
      attackerTimedOut: attacker_timed_out,
      defenderTimedOut: defender_timed_out,
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
