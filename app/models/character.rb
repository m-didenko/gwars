class Character < ApplicationRecord
  belongs_to :user
  has_one :queue_entry, dependent: :destroy

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
end
