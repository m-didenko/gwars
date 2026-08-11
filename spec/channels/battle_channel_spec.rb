require "rails_helper"

RSpec.describe BattleChannel, type: :channel do
  let(:one) { create(:character) }
  let(:two) { create(:character) }
  let(:battle) { create(:battle, :active, player_one: one, player_two: two) }

  it "streams the battle to a participant" do
    stub_connection current_user: one.user

    subscribe(id: battle.id)

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_for(battle)
  end

  it "streams the same battle to the other participant too" do
    stub_connection current_user: two.user

    subscribe(id: battle.id)

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_for(battle)
  end

  # The whole point of the participant check: without it, anyone who guesses
  # a battle id could subscribe and watch — or, worse, a future change to the
  # payload could leak something battle-specific to a spectator.
  it "rejects a signed-in commander who is not part of this battle" do
    outsider = create(:character)
    stub_connection current_user: outsider.user

    subscribe(id: battle.id)

    expect(subscription).to be_rejected
  end

  it "rejects a subscription to a battle that does not exist" do
    stub_connection current_user: one.user

    subscribe(id: -1)

    expect(subscription).to be_rejected
  end
end
