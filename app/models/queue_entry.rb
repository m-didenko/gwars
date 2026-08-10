# A commander waiting in the lobby for anyone to duel. The row exists only
# while they wait: pairing deletes it, and so does leaving the queue.
class QueueEntry < ApplicationRecord
  belongs_to :character

  validates :character_id, uniqueness: true

  scope :in_line, -> { order(:created_at, :id) }
end
