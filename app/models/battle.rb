class Battle < ApplicationRecord
  # Field geometry, expressed in field units: the battlefield spans 0..100.
  FIELD_MIN = 0
  FIELD_MAX = 100
  TANK_LENGTH = 5
  TANK_HALF = TANK_LENGTH / 2.0   # only a shell landing this close to the centre does anything
  # Rolls are spaced wider than the tank is wide, so committing to any move
  # escapes a shot aimed dead-on at where you were standing. Aiming between two
  # neighbouring options still clips either one, for less damage — that hedge is
  # the whole read.
  MOVE_OPTIONS = [-9, -6, -3, 0, 3, 6, 9].freeze
  MIN_SEPARATION = 12             # tanks may never close in tighter than this
  START_POSITIONS = { one: 20, two: 80 }.freeze

  belongs_to :player_one, class_name: "Character"
  belongs_to :player_two, class_name: "Character"
  belongs_to :attacker, class_name: "Character", optional: true
  belongs_to :winner, class_name: "Character", optional: true

  has_many :battle_turns, dependent: :destroy

  enum :status, { pending: 0, active: 1, finished: 2 }

  validates :player_two_id, uniqueness: {
    scope: :player_one_id, message: "battle with this opponent already exists"
  }, if: -> { pending? || active? }

  def accept!
    raise "Battle already started" unless pending?

    transaction do
      update!(
        status: :active,
        attacker: player_one,
        turn_number: 1,
        player_one_hp: player_one.max_hp,
        player_two_hp: player_two.max_hp,
        player_one_position: START_POSITIONS[:one],
        player_two_position: START_POSITIONS[:two]
      )
      open_turn!
    end

    broadcast_state!
  end

  def participant?(character)
    character.present? && character.id.in?([player_one_id, player_two_id])
  end

  def defender
    return nil if attacker.nil?

    attacker_id == player_one_id ? player_two : player_one
  end

  def role_for(character)
    return :spectator unless participant?(character)
    return :attacker if attacker_id == character.id
    return :defender if defender&.id == character.id

    :spectator
  end

  def side_of(character)
    character.id == player_one_id ? "one" : "two"
  end

  def hp_for(character)
    character.id == player_one_id ? player_one_hp : player_two_hp
  end

  def position_for(character)
    character.id == player_one_id ? player_one_position : player_two_position
  end

  def current_turn
    battle_turns.find_by(turn_number: turn_number)
  end

  # Everything both browsers need to render themselves. Deliberately identical
  # for both players: a pending decision is reported only as "committed: true",
  # never as the value, so this is safe to put on a shared stream.
  def state_payload
    turn = current_turn

    {
      status: status,
      turnNumber: turn_number,
      attackerSide: attacker && side_of(attacker),
      winnerSide: winner && side_of(winner),
      positions: { one: player_one_position, two: player_two_position },
      hp: { one: player_one_hp, two: player_two_hp },
      maxHp: { one: player_one.max_hp, two: player_two.max_hp },
      committed: { attacker: turn&.fired? || false, defender: turn&.moved? || false },
      replay: last_resolved_turn&.animation_payload(self)
    }
  end

  def broadcast_state!
    BattleChannel.broadcast_to(self, state_payload)
  end

  def last_resolved_turn
    battle_turns.where.not(resolved_at: nil).order(:turn_number).last
  end

  # The attacker commits the coordinate they are firing at. The defender never
  # sees it until the round resolves.
  def submit_aim!(character, aim_x)
    with_lock do
      turn = require_open_turn!
      raise "You are not the attacker this turn" unless attacker_id == character.id
      raise "You already fired this turn" if turn.aim_x.present?

      turn.update!(aim_x: aim_x.to_f.clamp(FIELD_MIN, FIELD_MAX))
      resolve_turn!(turn) if turn.ready?
    end

    # Broadcast outside the lock so subscribers never see pre-commit state.
    broadcast_state!
  end

  # The defender commits how far to roll. The attacker never sees it until the
  # round resolves.
  def submit_move!(character, delta)
    with_lock do
      turn = require_open_turn!
      raise "You are not the defender this turn" unless defender&.id == character.id
      raise "You already moved this turn" unless turn.move_delta.nil?
      raise "That is not a legal roll" unless MOVE_OPTIONS.include?(delta.to_i)

      turn.update!(move_delta: delta.to_i)
      resolve_turn!(turn) if turn.ready?
    end

    broadcast_state!
  end

  private

  def require_open_turn!
    raise "Battle is not active" unless active?

    current_turn or raise "No open turn"
  end

  def open_turn!
    battle_turns.create!(
      turn_number: turn_number,
      attacker_id: attacker.id,
      defender_id: defender.id,
      attacker_position: position_for(attacker)
    )
  end

  # Both decisions are in: slide the defender, drop the shell, apply damage,
  # then hand the gun to the other player.
  def resolve_turn!(turn)
    defending = defender
    moved_from = position_for(defending)
    moved_to = clamp_position(moved_from + turn.move_delta, position_for(attacker))

    distance = (turn.aim_x.to_f - moved_to).abs
    damage = damage_for(distance, defending)
    hp_before = hp_for(defending)
    hp_after = [hp_before - damage, 0].max

    turn.update!(
      defender_position_before: moved_from,
      defender_position_after: moved_to,
      distance: distance,
      hit: damage.positive?,
      damage: damage,
      defender_hp_before: hp_before,
      defender_hp_after: hp_after,
      resolved_at: Time.current
    )

    assign_position(defending, moved_to)
    assign_hp(defending, hp_after)

    if hp_after.zero?
      self.status = :finished
      self.winner = attacker
      self.attacker = nil
    else
      self.attacker = defending
      self.turn_number += 1
    end

    save!
    open_turn! if active?
  end

  # A clean miss does nothing at all — you have to actually land the shell on
  # the hull.
  def damage_for(distance, defending)
    return 0 if distance > TANK_HALF

    # Dead centre lands full damage, the edge of the treads lands ~45%.
    ratio = 1 - (distance / TANK_HALF) * 0.55
    [(attacker.attack * 3 * ratio).round - defending.defense, 1].max
  end

  def clamp_position(position, opponent_position)
    kept_apart = if position < opponent_position
      [position, opponent_position - MIN_SEPARATION].min
    else
      [position, opponent_position + MIN_SEPARATION].max
    end

    kept_apart.clamp(FIELD_MIN + TANK_HALF, FIELD_MAX - TANK_HALF).round
  end

  def assign_position(character, value)
    character.id == player_one_id ? self.player_one_position = value : self.player_two_position = value
  end

  def assign_hp(character, value)
    character.id == player_one_id ? self.player_one_hp = value : self.player_two_hp = value
  end
end
