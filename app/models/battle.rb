class Battle < ApplicationRecord
  # Field geometry, expressed in field units: the battlefield spans 0..100.
  FIELD_MIN = 0
  FIELD_MAX = 100
  TANK_LENGTH = 5
  TANK_HALF = TANK_LENGTH / 2.0   # anything closer than this is a hit on the hull

  # Damage by how far the shell landed from the tank's centre. The tank is 5
  # long, so the first three bands are one-unit slices of the hull — dead centre
  # hurts most, the treads least — and the last two are shrapnel landing just
  # short or just past it. The exact figure is rolled inside the band.
  DAMAGE_BANDS = [
    [0.5, 25..30],
    [1.5, 15..20],
    [2.5, 5..10],
    [3.5, 2..4],
    [4.5, 1..2]
  ].freeze

  MAX_DAMAGE = DAMAGE_BANDS.first.last.max
  MAX_MOVE = 9                    # the defender may roll anywhere within this
  MIN_SEPARATION = 12             # tanks may never close in tighter than this
  START_POSITIONS = { one: 20, two: 80 }.freeze

  # How long a player has to decide. Running out is a legal outcome, not an
  # error: the attacker simply does not fire and the defender simply holds
  # still, so a battle can never stall on someone who walked away.
  TURN_SECONDS = 30

  # A player who sits out five turns running — attacker not firing, defender
  # not rolling — forfeits. Without this an abandoned battle just sits open
  # forever: nobody watching means resolve_if_expired! never gets nudged, and
  # even if it did, a walked-away opponent would otherwise never actually lose.
  MAX_MISSED_TURNS = 5

  # How many resolved rounds the battle log keeps on screen. A short, scrolling
  # window rather than the whole history — plenty to see the damage mechanics
  # in action without turning the panel into a full match transcript.
  RECENT_LOG_LIMIT = 5

  belongs_to :player_one, class_name: "Character"
  belongs_to :player_two, class_name: "Character"
  belongs_to :attacker, class_name: "Character", optional: true
  belongs_to :winner, class_name: "Character", optional: true

  has_many :battle_turns, dependent: :destroy

  enum :status, { pending: 0, active: 1, finished: 2 }

  validate :opponent_is_someone_else
  validate :no_unfinished_battle_with_opponent, if: -> { pending? || active? }

  # Persists life back to both commanders and pays out the winner's XP. A
  # plain callback rather than a call at each of resolve_turn!'s two finish
  # branches (HP hitting zero, or a miss-streak forfeit) — both already funnel
  # through the same save!, so this fires exactly once regardless of which
  # one ended the fight.
  after_update :settle_characters!, if: -> { saved_change_to_status? && finished? }

  def accept!
    raise "Battle already started" unless pending?
    raise "Both commanders must recover before their next battle" \
      unless player_one.ready_for_battle? && player_two.ready_for_battle?

    transaction do
      update!(
        status: :active,
        attacker: player_one,
        turn_number: 1,
        # Not always a fresh max_hp: life carries over between battles, so a
        # commander who was still healing when the clock allowed them back in
        # starts this fight at whatever they had recovered to.
        player_one_hp: player_one.current_life,
        player_two_hp: player_two.current_life,
        player_one_position: START_POSITIONS[:one],
        player_two_position: START_POSITIONS[:two]
      )
      open_turn!

      # Starting a duel takes both players out of the lobby. Matchmaking already
      # claimed their places, but a challenge accepted from the duels page has
      # not — and someone who is fighting must not be waiting for a second fight.
      QueueEntry.where(character_id: [player_one_id, player_two_id]).delete_all
    end

    broadcast_state!
    LobbyChannel.queue_changed!
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

  # Everything both browsers need to render themselves. Without a viewer this is
  # deliberately identical for both players — a pending decision is reported only
  # as "committed: true", never as the value — so it is safe on a shared stream.
  #
  # Pass a viewer and it also carries back that player's *own* committed choice,
  # so they can see what they locked in. Only the page render does that; the
  # broadcast never does, which is what keeps it out of the opponent's hands.
  def state_payload(viewer = nil)
    turn = current_turn

    payload = {
      status: status,
      turnNumber: turn_number,
      attackerSide: attacker && side_of(attacker),
      winnerSide: winner && side_of(winner),
      positions: { one: player_one_position, two: player_two_position },
      hp: { one: player_one_hp, two: player_two_hp },
      maxHp: { one: player_one.max_hp, two: player_two.max_hp },
      committed: { attacker: turn&.fired? || false, defender: turn&.moved? || false },
      # How many turns in a row each player has sat out. Not a secret — it is
      # just a tally of the attackerTimedOut/defenderTimedOut flags already
      # visible in every resolved turn's replay — so it is fine on the shared
      # stream.
      missedTurns: { one: player_one_miss_streak, two: player_two_miss_streak },
      maxMissedTurns: MAX_MISSED_TURNS,
      turnSeconds: TURN_SECONDS,
      # Seconds left rather than the wall-clock deadline: the browser counts
      # down from whatever number it receives, so a device with a skewed clock
      # still agrees with the server about when the turn ends.
      turnEndsIn: (turn&.seconds_left if active?),
      replay: last_resolved_turn&.animation_payload(self),
      # Newest first, like any activity feed. Safe on the shared stream for the
      # same reason a single replay is: a resolved round has no secrets left.
      log: recent_turns.map { |t| t.animation_payload(self) }
    }

    if viewer && turn
      payload[:you] = {
        aim: (turn.aim_x&.to_f if turn.attacker_id == viewer.id),
        move: (turn.move_delta if turn.defender_id == viewer.id)
      }
    end

    payload
  end

  def broadcast_state!
    BattleChannel.broadcast_to(self, state_payload)
  end

  def last_resolved_turn
    battle_turns.where.not(resolved_at: nil).order(:turn_number).last
  end

  def recent_turns(limit = RECENT_LOG_LIMIT)
    battle_turns.where.not(resolved_at: nil).order(turn_number: :desc).limit(limit)
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
      raise "That is further than you can roll" if delta.to_i.abs > MAX_MOVE

      turn.update!(move_delta: delta.to_i)
      resolve_turn!(turn) if turn.ready?
    end

    broadcast_state!
  end

  # The clock ran out. Whoever is still watching nudges the server, but the
  # server re-checks the deadline itself, so an early or forged nudge does
  # nothing and two nudges arriving together resolve the turn only once — the
  # second finds the next turn's deadline sitting in the future.
  #
  # Nobody watching means nobody nudging, and an abandoned battle simply waits.
  # That is deliberate: the first player back resolves the one stale turn and
  # starts the next on a full clock instead of losing rounds nobody was present
  # for. Being present while your opponent is away is what lets you hit them.
  def resolve_if_expired!
    expired = false

    with_lock do
      turn = current_turn
      next unless active? && turn&.expired?

      turn.attacker_timed_out = !turn.fired?
      turn.defender_timed_out = !turn.moved?
      resolve_turn!(turn)
      expired = true
    end

    broadcast_state! if expired
    expired
  end

  private

  # Both commanders keep whatever HP they finished with, win or lose — that
  # is what makes life a resource that persists across battles instead of
  # resetting to full every time. Only the winner is paid XP; the margin is
  # their final HP minus the loser's, so grinding out a narrow win still pays
  # out, floored by Character::MIN_WIN_XP so even a lopsided one always does.
  def settle_characters!
    player_one.replenish_life!(player_one_hp)
    player_two.replenish_life!(player_two_hp)

    return unless winner

    loser_hp = winner_id == player_one_id ? player_two_hp : player_one_hp
    xp = [hp_for(winner) - loser_hp, Character::MIN_WIN_XP].max
    winner.grant_experience!(xp)
  end

  def opponent_is_someone_else
    return if player_one_id.nil? || player_one_id != player_two_id

    errors.add(:base, "You cannot challenge yourself")
  end

  # One live battle per pair. A finished one must not block the rematch, which
  # rules out a plain uniqueness validation: its `if:` decides whether to run,
  # but the query it runs still counts every battle these two have ever had.
  #
  # The pair is matched in both directions too — a challenge is the same battle
  # whichever side sent it, so an open one already covers the return challenge.
  def no_unfinished_battle_with_opponent
    return if player_one_id.nil? || player_two_id.nil?

    pair = [player_one_id, player_two_id]
    rivals = Battle.where.not(status: :finished)
                   .where(player_one_id: pair, player_two_id: pair)
    rivals = rivals.where.not(id: id) if persisted?

    return unless rivals.exists?

    errors.add(:base, "You already have an unfinished battle with this commander")
  end

  def require_open_turn!
    raise "Battle is not active" unless active?

    current_turn or raise "No open turn"
  end

  def open_turn!
    battle_turns.create!(
      turn_number: turn_number,
      attacker_id: attacker.id,
      defender_id: defender.id,
      attacker_position: position_for(attacker),
      deadline_at: TURN_SECONDS.seconds.from_now
    )
  end

  # Both decisions are in: slide the defender, drop the shell, apply damage,
  # then hand the gun to the other player.
  def resolve_turn!(turn)
    attacking = attacker
    defending = defender
    moved_from = position_for(defending)
    # A defender who ran out of time holds still.
    moved_to = clamp_position(moved_from + (turn.move_delta || 0), position_for(attacker))

    # An attacker who ran out of time gets no shot at all, so there is no
    # landing point and nothing to be near — distance stays nil rather than
    # collapsing to coordinate zero.
    distance = turn.fired? ? (turn.aim_x.to_f - moved_to).abs : nil
    damage = distance ? damage_for(distance) : 0
    hp_before = hp_for(defending)
    hp_after = [hp_before - damage, 0].max

    turn.update!(
      move_delta: turn.move_delta || 0,
      defender_position_before: moved_from,
      defender_position_after: moved_to,
      distance: distance,
      # Only a hit on the hull; shrapnel still does damage but reads differently.
      hit: distance ? distance <= TANK_HALF : false,
      damage: damage,
      defender_hp_before: hp_before,
      defender_hp_after: hp_after,
      resolved_at: Time.current
    )

    assign_position(defending, moved_to)
    assign_hp(defending, hp_after)

    bump_miss_streak(attacking, turn.attacker_timed_out)
    bump_miss_streak(defending, turn.defender_timed_out)
    forfeiter = missed_too_many_turns

    if hp_after.zero?
      self.status = :finished
      self.winner = attacking
      self.attacker = nil
    elsif forfeiter
      self.status = :finished
      self.winner = (forfeiter.id == attacking.id ? defending : attacking)
      self.attacker = nil
    else
      self.attacker = defending
      self.turn_number += 1
    end

    save!
    open_turn! if active?
  end

  # A hit streak resets the streak; a timeout extends it. Tracked per player,
  # not per role, because attacker and defender swap every turn — five misses
  # "in a row" means five of that player's own turns, whichever side they were
  # standing on each time.
  def bump_miss_streak(character, missed)
    assign_miss_streak(character, missed ? miss_streak_for(character) + 1 : 0)
  end

  def missed_too_many_turns
    return player_one if player_one_miss_streak >= MAX_MISSED_TURNS
    return player_two if player_two_miss_streak >= MAX_MISSED_TURNS

    nil
  end

  def miss_streak_for(character)
    character.id == player_one_id ? player_one_miss_streak : player_two_miss_streak
  end

  def assign_miss_streak(character, value)
    character.id == player_one_id ? self.player_one_miss_streak = value : self.player_two_miss_streak = value
  end

  def damage_for(distance)
    band = DAMAGE_BANDS.find { |limit, _| distance <= limit }

    band ? rand(band.last) : 0
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
