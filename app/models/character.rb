class Character < ApplicationRecord
  belongs_to :user
  has_one :queue_entry, dependent: :destroy

  # Life regenerates outside of battle rather than after it: a commander who
  # finishes badly hurt has to sit out, not just click straight into another
  # fight. max_hp doubles as both the in-battle HP pool and the life cap, so
  # there is one number for "fully healthy" instead of two that could drift
  # apart.
  LIFE_REGEN_PER_MINUTE = 5
  BATTLE_READY_LIFE = 90

  # XP needed to clear a level doubles every level: 500, 1000, 2000, ... A
  # win never grants less than this floor, so even a lopsided loss for the
  # opponent still moves the needle.
  LEVEL_BASE_XP = 500
  MIN_WIN_XP = 10

  validates :name, presence: true, uniqueness: true
  validates :max_hp, :attack, :defense, :gold, numericality: { only_integer: true }

  # The duel this commander is in the middle of, if any. A pending challenge
  # deliberately does not count: it has not started, so it should not lock
  # anyone out of the rest of the app.
  def ongoing_battle
    Battle.active
          .where(player_one_id: id)
          .or(Battle.active.where(player_two_id: id))
          .order(:created_at)
          .first
  end

  # Life the moment it was last written (after a battle) plus whatever has
  # regenerated since, capped at max_hp. Computed lazily rather than ticked by
  # a job, the same way a battle turn's deadline is checked on read rather
  # than on a timer.
  def current_life
    return max_hp if life >= max_hp || life_replenished_at.nil?

    elapsed_minutes = (Time.current - life_replenished_at) / 60.0
    [life + (elapsed_minutes * LIFE_REGEN_PER_MINUTE).floor, max_hp].min
  end

  def ready_for_battle?
    current_life >= BATTLE_READY_LIFE
  end

  # How long until current_life crosses BATTLE_READY_LIFE, for a countdown on
  # the character page. Never negative, and 0 once already ready.
  def seconds_until_ready
    return 0 if ready_for_battle?

    minutes_needed = (BATTLE_READY_LIFE - life).to_f / LIFE_REGEN_PER_MINUTE
    [(life_replenished_at + minutes_needed.minutes) - Time.current, 0].max.round
  end

  # Written once, right when a battle finishes: the HP a commander walked
  # away with becomes the life they start regenerating from.
  def replenish_life!(hp)
    update!(life: hp, life_replenished_at: Time.current)
  end

  def grant_experience!(amount)
    new_xp = experience + amount
    update!(experience: new_xp, level: self.class.level_for_experience(new_xp))
  end

  # How far into the current level's XP band this character sits, and how
  # wide that band is — everything a progress bar needs.
  def xp_into_level
    experience - self.class.xp_for_level(level)
  end

  def xp_for_next_level
    self.class.xp_for_level(level + 1) - self.class.xp_for_level(level)
  end

  # Cumulative XP required to have reached `level`, counting from level 1 at
  # zero. Each level costs twice the previous one's 500-XP step.
  def self.xp_for_level(level)
    return 0 if level <= 1

    LEVEL_BASE_XP * (2**(level - 1) - 1)
  end

  def self.level_for_experience(xp)
    level = 1
    level += 1 while xp >= xp_for_level(level + 1)
    level
  end
end
