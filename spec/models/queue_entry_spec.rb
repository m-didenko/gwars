require "rails_helper"

RSpec.describe QueueEntry, type: :model do
  it "will not let the same character queue twice" do
    character = create(:character)
    create(:queue_entry, character: character)

    duplicate = build(:queue_entry, character: character)

    expect(duplicate).not_to be_valid
  end

  describe ".in_line" do
    it "orders the longest-waiting character first" do
      later = create(:queue_entry, character: create(:character), created_at: 1.minute.ago)
      earlier = create(:queue_entry, character: create(:character), created_at: 5.minutes.ago)

      expect(QueueEntry.in_line.to_a).to eq([earlier, later])
    end
  end
end
