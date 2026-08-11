require "rails_helper"

RSpec.describe "Battles", type: :request do
  let(:character) { create(:character) }
  let(:user) { character.user }
  let(:opponent) { create(:character) }

  before { sign_in user }

  describe "GET /battles" do
    it "lists the commander's own battles" do
      get battles_path

      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /battles/:id" do
    it "is visible to a participant" do
      battle = create(:battle, player_one: character, player_two: opponent, status: :pending)

      get battle_path(battle)

      expect(response).to have_http_status(:ok)
    end

    it "turns away anyone who is not a participant" do
      battle = create(:battle, player_one: opponent, player_two: create(:character), status: :pending)

      get battle_path(battle)

      expect(response).to redirect_to(battles_path)
    end

    it "settles a turn whose clock ran out while nobody was watching" do
      battle = create(:battle, :active, player_one: character, player_two: opponent)
      battle.current_turn.update!(deadline_at: 1.second.ago)

      get battle_path(battle)

      expect(battle.reload.turn_number).to eq(2)
    end
  end

  describe "GET /battles/:id/state" do
    it "answers a participant with their own view of the battle" do
      battle = create(:battle, :active, player_one: character, player_two: opponent)

      get state_battle_path(battle), as: :json

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body).to have_key("you")
    end

    it "is forbidden for a non-participant" do
      battle = create(:battle, :active, player_one: opponent, player_two: create(:character))

      get state_battle_path(battle), as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /battles/:id/log" do
    it "returns the full resolved-turn history for a participant" do
      battle = create(:battle, :active, player_one: character, player_two: opponent)
      battle.submit_aim!(battle.attacker, battle.position_for(battle.defender))
      battle.submit_move!(battle.defender, 0)

      get log_battle_path(battle), as: :json

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["turns"].size).to eq(1)
    end

    it "is forbidden for a non-participant" do
      battle = create(:battle, :active, player_one: opponent, player_two: create(:character))

      get log_battle_path(battle), as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "the battle-lock guard" do
    it "redirects any other page back to an ongoing battle" do
      battle = create(:battle, :active, player_one: character, player_two: opponent)

      get battles_path

      expect(response).to redirect_to(battle_path(battle))
    end

    it "answers a JSON request with 409 and the battle id instead of redirecting" do
      battle = create(:battle, :active, player_one: character, player_two: opponent)

      get battles_path, as: :json

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["battleId"]).to eq(battle.id)
    end

    it "lets the battle's own page through" do
      battle = create(:battle, :active, player_one: character, player_two: opponent)

      get battle_path(battle)

      expect(response).to have_http_status(:ok)
    end

    it "does not hold a merely pending challenge against anyone" do
      create(:battle, player_one: character, player_two: opponent, status: :pending)

      get battles_path

      expect(response).to have_http_status(:ok)
    end
  end
end
