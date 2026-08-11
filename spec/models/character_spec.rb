require "rails_helper"

RSpec.describe Character, type: :model do
  describe "validations" do
    it "requires a name" do
      character = build(:character, name: nil)
      expect(character).not_to be_valid
      expect(character.errors[:name]).to be_present
    end

    it "requires a unique name" do
      create(:character, name: "Duplicate")
      character = build(:character, name: "Duplicate")

      expect(character).not_to be_valid
    end

    it "requires integer stats" do
      character = build(:character, max_hp: 1.5)
      expect(character).not_to be_valid
    end
  end

  describe "#ongoing_battle" do
    let(:character) { create(:character) }
    let(:opponent) { create(:character) }

    it "is nil with no battles at all" do
      expect(character.ongoing_battle).to be_nil
    end

    it "ignores a pending challenge nobody has accepted" do
      create(:battle, player_one: character, player_two: opponent, status: :pending)

      expect(character.ongoing_battle).to be_nil
    end

    it "finds an active battle regardless of which side the character is on" do
      battle = create(:battle, :active, player_one: opponent, player_two: character)

      expect(character.ongoing_battle).to eq(battle)
    end

    it "ignores a finished battle" do
      battle = create(:battle, :active, player_one: character, player_two: opponent)
      battle.update!(status: :finished)

      expect(character.ongoing_battle).to be_nil
    end
  end

  describe "#current_life" do
    it "is max_hp for a character who has never fought" do
      character = build(:character, life: 100, life_replenished_at: nil)

      expect(character.current_life).to eq(character.max_hp)
    end

    it "is the stored life with no time elapsed" do
      character = build(:character, life: 40, life_replenished_at: Time.current)

      expect(character.current_life).to eq(40)
    end

    it "regenerates at 5 per minute since it was last written" do
      character = build(:character, life: 0, life_replenished_at: 10.minutes.ago)

      expect(character.current_life).to eq(50)
    end

    it "never exceeds max_hp no matter how long it has been" do
      character = build(:character, life: 0, life_replenished_at: 1.day.ago)

      expect(character.current_life).to eq(character.max_hp)
    end
  end

  describe "#ready_for_battle?" do
    it "is false below the 90-life threshold" do
      character = build(:character, life: 89, life_replenished_at: Time.current)

      expect(character).not_to be_ready_for_battle
    end

    it "is true at or above the 90-life threshold" do
      character = build(:character, life: 90, life_replenished_at: Time.current)

      expect(character).to be_ready_for_battle
    end
  end

  describe "#seconds_until_ready" do
    it "is zero once already ready" do
      character = build(:character, life: 100, life_replenished_at: nil)

      expect(character.seconds_until_ready).to eq(0)
    end

    it "counts down to the moment life crosses the ready threshold" do
      character = build(:character, life: 0, life_replenished_at: Time.current)

      # (90 - 0) / 5 per minute = 18 minutes = 1080 seconds
      expect(character.seconds_until_ready).to eq(1080)
    end
  end

  describe "#replenish_life!" do
    it "writes the given HP as life and anchors the regen clock to now" do
      character = create(:character, life: 100, life_replenished_at: nil)

      character.replenish_life!(37)

      expect(character.reload.life).to eq(37)
      expect(character.life_replenished_at).to be_within(2.seconds).of(Time.current)
    end
  end

  describe "XP and leveling" do
    describe ".xp_for_level" do
      it "requires no XP for level 1" do
        expect(Character.xp_for_level(1)).to eq(0)
      end

      it "doubles the per-level cost each level" do
        expect(Character.xp_for_level(2)).to eq(500)
        expect(Character.xp_for_level(3)).to eq(1500)
        expect(Character.xp_for_level(4)).to eq(3500)
        expect(Character.xp_for_level(5)).to eq(7500)
      end
    end

    describe ".level_for_experience" do
      it "stays at the floor level until the next threshold is met" do
        expect(Character.level_for_experience(0)).to eq(1)
        expect(Character.level_for_experience(499)).to eq(1)
        expect(Character.level_for_experience(500)).to eq(2)
        expect(Character.level_for_experience(1499)).to eq(2)
        expect(Character.level_for_experience(1500)).to eq(3)
      end
    end

    describe "#grant_experience!" do
      it "adds to experience and recomputes the level" do
        character = create(:character, level: 1, experience: 0)

        character.grant_experience!(10)
        expect(character.reload).to have_attributes(experience: 10, level: 1)

        character.grant_experience!(495)
        expect(character.reload).to have_attributes(experience: 505, level: 2)
      end

      it "can cross more than one level in a single award" do
        character = create(:character, level: 1, experience: 0)

        character.grant_experience!(2_505)

        expect(character.reload).to have_attributes(experience: 2_505, level: 3)
      end
    end

    describe "#xp_into_level / #xp_for_next_level" do
      it "measures progress within the current level's band" do
        character = build(:character, level: 2, experience: 700)

        expect(character.xp_into_level).to eq(200)
        expect(character.xp_for_next_level).to eq(1_000)
      end
    end
  end
end
