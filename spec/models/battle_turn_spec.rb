require "rails_helper"

RSpec.describe BattleTurn, type: :model do
  describe "#fired? / #moved? / #ready?" do
    it "is neither fired nor moved right after opening" do
      turn = create(:battle_turn)

      expect(turn).not_to be_fired
      expect(turn).not_to be_moved
      expect(turn).not_to be_ready
    end

    it "is fired once an aim is set, moved once a move_delta is set (even zero)" do
      turn = create(:battle_turn, aim_x: 50, move_delta: 0)

      expect(turn).to be_fired
      expect(turn).to be_moved
      expect(turn).to be_ready
    end

    it "is not ready with only one side committed" do
      turn = create(:battle_turn, aim_x: 50)

      expect(turn).not_to be_ready
    end
  end

  describe "#resolved?" do
    it "is false until resolved_at is set" do
      expect(create(:battle_turn).resolved?).to be false
    end

    it "is true once resolved_at is set" do
      expect(create(:battle_turn, resolved_at: Time.current).resolved?).to be true
    end
  end

  describe "#expired?" do
    it "never expires with no deadline" do
      turn = create(:battle_turn, deadline_at: nil)

      expect(turn).not_to be_expired
    end

    it "is not expired before the deadline" do
      turn = create(:battle_turn, deadline_at: 5.seconds.from_now)

      expect(turn).not_to be_expired
    end

    it "is expired once the deadline has passed" do
      turn = create(:battle_turn, deadline_at: 1.second.ago)

      expect(turn).to be_expired
    end
  end

  describe "#seconds_left" do
    it "is nil with no deadline" do
      expect(create(:battle_turn, deadline_at: nil).seconds_left).to be_nil
    end

    it "never goes negative" do
      turn = create(:battle_turn, deadline_at: 5.seconds.ago)

      expect(turn.seconds_left).to eq(0)
    end

    it "counts down toward the deadline" do
      turn = create(:battle_turn, deadline_at: 10.seconds.from_now)

      expect(turn.seconds_left).to be_within(0.5).of(10)
    end
  end

  describe "#animation_payload" do
    it "carries everything the replay needs, with no landing point for a shot never fired" do
      battle = create(:battle, :active)
      turn = battle.current_turn
      turn.update!(
        attacker_timed_out: true,
        defender_timed_out: false,
        defender_position_before: battle.position_for(battle.defender),
        defender_position_after: battle.position_for(battle.defender),
        distance: nil,
        hit: false,
        damage: 0,
        defender_hp_before: battle.hp_for(battle.defender),
        defender_hp_after: battle.hp_for(battle.defender),
        resolved_at: Time.current
      )

      payload = turn.animation_payload(battle)

      expect(payload[:aimX]).to be_nil
      expect(payload[:attackerTimedOut]).to be true
      expect(payload[:attackerSide]).to eq(battle.side_of(battle.attacker))
    end
  end
end
