require "rails_helper"

RSpec.describe Battle, type: :model do
  let(:one) { create(:character, name: "Attacker One") }
  let(:two) { create(:character, name: "Defender Two") }

  # Pins every hit to a known damage figure so a battle can be driven to a
  # decisive HP total without depending on the random roll inside a band.
  def stub_damage!(battle, amount)
    allow(battle).to receive(:rand).and_return(amount)
  end

  def fire_and_move!(battle, aim: nil, delta: 0)
    turn = battle.current_turn
    battle.submit_aim!(turn.attacker, aim || battle.position_for(turn.defender))
    battle.submit_move!(turn.defender, delta)
  end

  describe "validations" do
    it "will not let a character challenge themselves" do
      battle = build(:battle, player_one: one, player_two: one)

      expect(battle).not_to be_valid
      expect(battle.errors[:base]).to include("You cannot challenge yourself")
    end

    it "blocks a second unfinished battle between the same pair" do
      create(:battle, player_one: one, player_two: two, status: :pending)
      rematch = build(:battle, player_one: one, player_two: two, status: :pending)

      expect(rematch).not_to be_valid
    end

    it "blocks the return challenge sent from the other side" do
      create(:battle, player_one: one, player_two: two, status: :pending)
      reverse_challenge = build(:battle, player_one: two, player_two: one, status: :pending)

      expect(reverse_challenge).not_to be_valid
    end

    it "allows a rematch once the earlier battle is finished" do
      create(:battle, player_one: one, player_two: two, status: :finished)
      rematch = build(:battle, player_one: one, player_two: two, status: :pending)

      expect(rematch).to be_valid
    end
  end

  describe "#accept!" do
    it "refuses to start an already-started battle" do
      battle = create(:battle, :active, player_one: one, player_two: two)

      expect { battle.accept! }.to raise_error(/already started/)
    end

    it "refuses to start while either commander is still recovering" do
      hurt = create(:character, :recovering)
      battle = create(:battle, player_one: one, player_two: hurt, status: :pending)

      expect { battle.accept! }.to raise_error(/recover/)
      expect(battle.reload).to be_pending
    end

    it "seeds each side's battle HP from current_life rather than a fresh max_hp" do
      healed = create(:character, life: 95, life_replenished_at: Time.current, max_hp: 100)
      battle = create(:battle, player_one: one, player_two: healed, status: :pending)

      battle.accept!

      expect(battle.player_two_hp).to eq(95)
      expect(battle.player_one_hp).to eq(one.max_hp)
    end

    it "opens the first turn with player_one attacking" do
      battle = create(:battle, player_one: one, player_two: two, status: :pending)

      battle.accept!

      expect(battle).to be_active
      expect(battle.attacker).to eq(one)
      expect(battle.turn_number).to eq(1)
      expect(battle.current_turn).to be_present
    end

    it "clears both commanders out of the matchmaking queue" do
      create(:queue_entry, character: one)
      create(:queue_entry, character: two)
      battle = create(:battle, player_one: one, player_two: two, status: :pending)

      battle.accept!

      expect(QueueEntry.where(character_id: [one.id, two.id])).to be_empty
    end
  end

  describe "the shared broadcast never carries an undecided value" do
    it "never includes a `you` section, whoever fired or moved" do
      battle = create(:battle, :active, player_one: one, player_two: two)

      expect(BattleChannel).to receive(:broadcast_to) do |_battle, payload|
        expect(payload).not_to have_key(:you)
        expect(payload[:committed]).to eq(attacker: true, defender: false)
      end

      battle.submit_aim!(one, battle.position_for(two))
    end

    it "reports a pending decision only as committed: true, never the figure itself" do
      battle = create(:battle, :active, player_one: one, player_two: two)
      battle.submit_aim!(one, 37.5)

      payload = battle.state_payload

      expect(payload[:committed]).to eq(attacker: true, defender: false)
      expect(payload.to_s).not_to include("37.5")
    end
  end

  describe "state_payload(viewer)" do
    it "carries back only the viewer's own committed decision" do
      battle = create(:battle, :active, player_one: one, player_two: two)
      battle.submit_aim!(one, 42.0)

      attacker_view = battle.state_payload(one)
      defender_view = battle.state_payload(two)

      expect(attacker_view[:you]).to eq(aim: 42.0, move: nil)
      expect(defender_view[:you]).to eq(aim: nil, move: nil)
    end
  end

  describe "#submit_aim! and #submit_move!" do
    let(:battle) { create(:battle, :active, player_one: one, player_two: two) }

    it "rejects a shot from whoever is not the attacker this turn" do
      expect { battle.submit_aim!(two, 50) }.to raise_error(/not the attacker/)
    end

    it "rejects a move from whoever is not the defender this turn" do
      expect { battle.submit_move!(one, 0) }.to raise_error(/not the defender/)
    end

    it "rejects firing twice in the same turn" do
      battle.submit_aim!(one, 50)

      expect { battle.submit_aim!(one, 60) }.to raise_error(/already fired/)
    end

    it "rejects a roll further than MAX_MOVE" do
      expect { battle.submit_move!(two, Battle::MAX_MOVE + 1) }.to raise_error(/further than/)
    end

    it "resolves the round only once both sides have committed" do
      battle.submit_aim!(one, battle.position_for(two))
      expect(battle.current_turn).not_to be_resolved

      battle.submit_move!(two, 0)
      expect(battle.reload.current_turn.resolved?).to be false # a fresh turn 2 has opened
      expect(battle.turn_number).to eq(2)
    end
  end

  describe "resolving a round" do
    let(:battle) { create(:battle, :active, player_one: one, player_two: two) }

    it "damages the defender and keeps their position within the field" do
      stub_damage!(battle, 20)

      fire_and_move!(battle, aim: battle.position_for(two), delta: 0)

      expect(battle.reload.player_two_hp).to eq(two.max_hp - 20)
    end

    it "clamps the defender's roll so the tanks never end up closer than MIN_SEPARATION" do
      fire_and_move!(battle, delta: Battle::MAX_MOVE) # rolling toward the attacker

      distance = (battle.player_one_position - battle.player_two_position).abs
      expect(distance).to be >= Battle::MIN_SEPARATION
    end

    it "hands the attack to the other side and advances the turn number" do
      fire_and_move!(battle)

      expect(battle.reload.attacker).to eq(two)
      expect(battle.turn_number).to eq(2)
    end

    it "finishes the battle and names a winner once HP reaches zero" do
      stub_damage!(battle, 100)

      fire_and_move!(battle, aim: battle.position_for(two))

      battle.reload
      expect(battle).to be_finished
      expect(battle.winner).to eq(one)
      expect(battle.player_two_hp).to eq(0)
    end

    it "leaves an attacker who ran out of time with no shell in flight" do
      turn = battle.current_turn
      turn.attacker_timed_out = true
      battle.send(:resolve_turn!, turn)

      expect(turn.reload.aim_x).to be_nil
      expect(turn.hit).to be false
      expect(turn.damage).to eq(0)
    end
  end

  describe "forfeiting after five missed turns in a row" do
    let(:battle) { create(:battle, :active, player_one: one, player_two: two) }

    it "ends the battle in the other player's favor, independent of HP" do
      Battle::MAX_MISSED_TURNS.times do
        turn = battle.current_turn
        turn.attacker_timed_out = true
        turn.defender_timed_out = true
        battle.send(:resolve_turn!, turn)
        break if battle.finished?
      end

      expect(battle).to be_finished
      expect(battle.player_one_hp).to eq(one.max_hp) # nobody ever landed a hit
      expect(battle.player_two_hp).to eq(two.max_hp)
    end

    it "resets both streaks the moment a round is fully played out" do
      turn = battle.current_turn
      turn.attacker_timed_out = true
      turn.defender_timed_out = true
      battle.send(:resolve_turn!, turn)
      expect(battle.player_one_miss_streak).to eq(1)
      expect(battle.player_two_miss_streak).to eq(1)

      fire_and_move!(battle) # a normal round: both sides act

      expect(battle.reload.player_one_miss_streak).to eq(0)
      expect(battle.reload.player_two_miss_streak).to eq(0)
    end
  end

  describe "#resolve_if_expired!" do
    let(:battle) { create(:battle, :active, player_one: one, player_two: two) }

    it "does nothing before the deadline" do
      expect(battle.resolve_if_expired!).to be false
      expect(battle.reload.turn_number).to eq(1)
    end

    it "resolves the stale turn once the deadline has passed" do
      battle.current_turn.update!(deadline_at: 1.second.ago)

      expect(battle.resolve_if_expired!).to be true
      expect(battle.reload.turn_number).to eq(2)
    end

    it "is a no-op the second time, since the new turn has a fresh deadline" do
      battle.current_turn.update!(deadline_at: 1.second.ago)
      battle.resolve_if_expired!

      expect(battle.resolve_if_expired!).to be false
    end
  end

  describe "settling characters when the battle ends" do
    it "writes each side's final HP back as life and pays the winner XP" do
      battle = create(:battle, :active, player_one: one, player_two: two)
      # Round 1: one (attacking) hits two for 70 — two survives at 30, so the
      # battle keeps going and the attack passes to two.
      # Round 2: two (now attacking) hits one for 100 — one dies at 0, ending
      # the battle with two as the winner, still sitting at their round-1 HP.
      allow(battle).to receive(:rand).and_return(70, 100)

      fire_and_move!(battle, aim: battle.position_for(battle.defender))
      fire_and_move!(battle, aim: battle.position_for(battle.defender))

      expect(battle.reload).to be_finished
      expect(battle.winner).to eq(two)
      expect(two.reload.life).to eq(30)
      expect(one.reload.life).to eq(0)
      expect(two.experience).to eq(30) # winner_hp(30) - loser_hp(0), above the floor
    end

    it "never pays less than Character::MIN_WIN_XP, even for a razor-thin margin" do
      battle = create(:battle, :active, player_one: one, player_two: two)
      # Round 1 leaves two at 5 HP; round 2 kills one outright. two wins by a
      # margin of only 5, which the floor bumps up to MIN_WIN_XP.
      allow(battle).to receive(:rand).and_return(95, 100)

      fire_and_move!(battle, aim: battle.position_for(battle.defender))
      fire_and_move!(battle, aim: battle.position_for(battle.defender))

      expect(battle.reload.winner).to eq(two)
      expect(two.reload.experience).to eq(Character::MIN_WIN_XP)
    end

    it "leaves the winner needing to recover too, if they were badly hurt along the way" do
      battle = create(:battle, :active, player_one: one, player_two: two)
      stub_damage!(battle, 20) # attacker and defender swap each round, so the hits land on both sides

      loop do
        fire_and_move!(battle, aim: battle.position_for(battle.defender))
        break if battle.reload.finished?
      end

      expect(battle.winner).to eq(one)
      expect(one.reload.life).to be < 90
      expect(one).not_to be_ready_for_battle
      expect(two.reload).not_to be_ready_for_battle
    end
  end
end
