class Character < ApplicationRecord
  belongs_to :user

  validates :name, presence: true, uniqueness: true
  validates :hp, :max_hp, :attack, :defense, :gold, numericality: { only_integer: true }

  def alive?
    hp.positive?
  end

  def full_heal!
    update!(hp: max_hp)
  end
end
