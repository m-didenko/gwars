require "rails_helper"

RSpec.describe LobbyChannel, type: :channel do
  it "streams both the personal match stream and the shared queue count" do
    character = create(:character)
    stub_connection current_user: character.user

    subscribe

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from(LobbyChannel.personal_stream(character))
    expect(subscription).to have_stream_from(LobbyChannel.queue_stream)
  end

  it "rejects a signed-in user with no character yet" do
    user = create(:user)
    stub_connection current_user: user

    subscribe

    expect(subscription).to be_rejected
  end

  describe ".matched!" do
    it "tells only the two participants, on their own personal streams" do
      one = create(:character)
      two = create(:character)
      bystander = create(:character)
      battle = create(:battle, :active, player_one: one, player_two: two)

      expect { LobbyChannel.matched!(battle) }
        .to have_broadcasted_to(LobbyChannel.personal_stream(one))
        .with(hash_including("type" => "matched", "battleId" => battle.id))

      expect { LobbyChannel.matched!(battle) }
        .to have_broadcasted_to(LobbyChannel.personal_stream(two))
        .with(hash_including("type" => "matched", "battleId" => battle.id))

      expect { LobbyChannel.matched!(battle) }
        .not_to have_broadcasted_to(LobbyChannel.personal_stream(bystander))
    end
  end

  describe ".queue_changed!" do
    it "broadcasts the current queue size to the shared stream, nobody's in particular" do
      create_list(:queue_entry, 2)

      expect { LobbyChannel.queue_changed! }
        .to have_broadcasted_to(LobbyChannel.queue_stream)
        .with(hash_including("type" => "queue", "waiting" => 2))
    end
  end
end
