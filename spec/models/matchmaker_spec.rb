require "rails_helper"

RSpec.describe Matchmaker do
  describe ".pair_next!" do
    it "does nothing with an empty queue" do
      expect(Matchmaker.pair_next!).to be_nil
    end

    it "does nothing with only one commander waiting" do
      create(:queue_entry, character: create(:character))

      expect(Matchmaker.pair_next!).to be_nil
    end

    it "pairs the two longest-waiting commanders and starts their battle" do
      earliest = create(:queue_entry, character: create(:character), created_at: 5.minutes.ago)
      next_up = create(:queue_entry, character: create(:character), created_at: 3.minutes.ago)
      create(:queue_entry, character: create(:character), created_at: 1.minute.ago) # not this round

      battle = Matchmaker.pair_next!

      expect(battle).to be_active
      expect(battle.participant?(earliest.character)).to be true
      expect(battle.participant?(next_up.character)).to be true
    end

    it "removes both matched commanders from the queue" do
      one = create(:queue_entry, character: create(:character), created_at: 2.minutes.ago)
      two = create(:queue_entry, character: create(:character), created_at: 1.minute.ago)

      Matchmaker.pair_next!

      expect(QueueEntry.where(id: [one.id, two.id])).to be_empty
    end

    it "notifies both commanders over their personal lobby stream" do
      one = create(:queue_entry, character: create(:character), created_at: 2.minutes.ago)
      two = create(:queue_entry, character: create(:character), created_at: 1.minute.ago)

      expect { Matchmaker.pair_next! }
        .to have_broadcasted_to(LobbyChannel.personal_stream(one.character))
        .and have_broadcasted_to(LobbyChannel.personal_stream(two.character))
    end

    # Documents current behavior rather than prescribing it: accept! raises if
    # either side is not ready_for_battle?, and pair_next! does not rescue
    # that. In normal play this cannot happen — LobbyController#join refuses
    # to queue a recovering character in the first place, and life never
    # drops outside of a battle — but a row inserted straight into the queue
    # (a bad migration, a console mistake) would blow up the whole matchmaking
    # run for every pair still behind it, not just this one.
    it "raises rather than silently skipping a pair when one side is not battle-ready" do
      hurt = create(:character, :recovering)
      create(:queue_entry, character: hurt, created_at: 2.minutes.ago)
      create(:queue_entry, character: create(:character), created_at: 1.minute.ago)

      expect { Matchmaker.pair_next! }.to raise_error(/recover/)
    end
  end

  describe ".run!" do
    it "returns an empty list when nobody is waiting" do
      expect(Matchmaker.run!).to eq([])
    end

    it "empties a pool of four into two separate battles" do
      4.times { create(:queue_entry, character: create(:character)) }

      started = Matchmaker.run!

      expect(started.size).to eq(2)
      expect(QueueEntry.count).to eq(0)
    end

    it "leaves the odd one out waiting for the next round" do
      characters = Array.new(5) { create(:character) }
      characters.each { |character| create(:queue_entry, character: character) }

      started = Matchmaker.run!

      expect(started.size).to eq(2)
      expect(QueueEntry.count).to eq(1)
    end
  end

  describe ".start_battle" do
    let(:one) { create(:character) }
    let(:two) { create(:character) }

    it "creates and accepts a fresh battle when the pair has no history" do
      battle = Matchmaker.start_battle(one, two)

      expect(battle).to be_active
    end

    it "accepts an existing pending challenge instead of opening a duplicate" do
      challenge = create(:battle, player_one: one, player_two: two, status: :pending)

      battle = Matchmaker.start_battle(one, two)

      expect(battle).to eq(challenge)
      expect(battle.reload).to be_active
    end

    it "hands back an already-active battle between the pair untouched" do
      ongoing = create(:battle, :active, player_one: one, player_two: two)

      battle = Matchmaker.start_battle(one, two)

      expect(battle).to eq(ongoing)
      expect(battle.reload).to be_active
    end
  end

  describe ".claim / .restore" do
    it "claim removes the row and reports success" do
      entry = create(:queue_entry, character: create(:character))

      expect(Matchmaker.claim(entry)).to be true
      expect(QueueEntry.exists?(entry.id)).to be false
    end

    it "claim reports failure when the row is already gone" do
      entry = create(:queue_entry, character: create(:character))
      entry.destroy

      expect(Matchmaker.claim(entry)).to be false
    end

    it "restore puts the character back at its original place in line" do
      original_time = 10.minutes.ago
      entry = create(:queue_entry, character: create(:character), created_at: original_time)
      Matchmaker.claim(entry)

      Matchmaker.restore(entry)

      restored = QueueEntry.find_by(character_id: entry.character_id)
      expect(restored.created_at).to be_within(1.second).of(original_time)
    end

    it "restore does not duplicate a row that is already back in the queue" do
      entry = create(:queue_entry, character: create(:character))

      Matchmaker.restore(entry)

      expect(QueueEntry.where(character_id: entry.character_id).count).to eq(1)
    end
  end
end
