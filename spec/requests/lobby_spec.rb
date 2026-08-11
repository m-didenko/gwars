require "rails_helper"

RSpec.describe "Lobby", type: :request do
  let(:character) { create(:character) }
  let(:user) { character.user }

  before { sign_in user }

  describe "POST /lobby/join" do
    it "queues a battle-ready commander" do
      post join_lobby_path, as: :json

      expect(response).to have_http_status(:ok)
      expect(QueueEntry.exists?(character: character)).to be true
    end

    it "refuses a commander who is still recovering, and leaves them out of the queue" do
      character.update!(life: 40, life_replenished_at: Time.current)

      post join_lobby_path, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(QueueEntry.exists?(character: character)).to be false
    end

    it "pairs up two waiting commanders into a battle" do
      opponent = create(:character)
      create(:queue_entry, character: opponent)

      post join_lobby_path, as: :json

      body = JSON.parse(response.body)
      expect(body["battleId"]).to be_present

      battle = Battle.find(body["battleId"])
      expect(battle).to be_active
      expect(battle.participant?(character)).to be true
      expect(battle.participant?(opponent)).to be true
    end
  end

  describe "POST /lobby/leave" do
    it "takes the commander back out of the queue" do
      create(:queue_entry, character: character)

      post leave_lobby_path, as: :json

      expect(QueueEntry.exists?(character: character)).to be false
    end
  end
end
