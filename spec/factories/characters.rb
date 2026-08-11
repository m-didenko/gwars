FactoryBot.define do
  factory :character do
    user
    sequence(:name) { |n| "Commander#{n}" }
    max_hp { 100 }
    attack { 10 }
    defense { 2 }
    gold { 0 }
    level { 1 }
    experience { 0 }
    life { 100 }
    life_replenished_at { nil }

    # A character who just walked out of a rough fight: not enough life left
    # to queue or challenge again yet.
    trait :recovering do
      life { 40 }
      life_replenished_at { 1.minute.ago }
    end
  end
end
