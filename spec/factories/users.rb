FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "commander#{n}@example.com" }
    password { "password123" }
  end
end
