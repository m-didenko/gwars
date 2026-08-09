class Character < ApplicationRecord
  belongs_to :user

  validates :name, presence: true, uniqueness: true
  validates :max_hp, :attack, :defense, :gold, numericality: { only_integer: true }
end
