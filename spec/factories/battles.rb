FactoryBot.define do
  factory :battle do
    association :player_one, factory: :character
    association :player_two, factory: :character
    status { :pending }

    # Goes through the real accept! rather than stubbing the fields it sets,
    # so a spec built on this trait exercises the same path production does
    # (and fails the same way accept! would if that path ever broke).
    trait :active do
      after(:create) { |battle| battle.accept! }
    end
  end
end
