require "rails_helper"

RSpec.describe "BattleTurns", type: :request do
  let(:character) { create(:character) }
  let(:user) { character.user }
  let(:opponent) { create(:character) }

  before { sign_in user }

  describe "POST /battles/:id/accept" do
    it "starts a pending challenge the commander was invited to" do
      battle = create(:battle, player_one: opponent, player_two: character, status: :pending)

      post accept_battle_path(battle), as: :json

      expect(response).to have_http_status(:no_content)
      expect(battle.reload).to be_active
    end

    it "answers 422 with the model's own message when it cannot be accepted" do
      battle = create(:battle, :active, player_one: opponent, player_two: character)

      post accept_battle_path(battle), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/already started/)
    end

    it "is forbidden for anyone who is not one of the two commanders" do
      battle = create(:battle, player_one: opponent, player_two: create(:character), status: :pending)

      post accept_battle_path(battle), as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /battles/:id/aim" do
    it "commits the attacker's shot" do
      battle = create(:battle, :active, player_one: character, player_two: opponent)

      post aim_battle_path(battle), params: { aim_x: 42 }, as: :json

      expect(response).to have_http_status(:no_content)
      expect(battle.reload.current_turn.aim_x.to_f).to eq(42.0)
    end

    it "answers 422 when it is not that commander's turn to fire" do
      battle = create(:battle, :active, player_one: opponent, player_two: character)

      post aim_battle_path(battle), params: { aim_x: 42 }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/not the attacker/)
    end
  end

  describe "POST /battles/:id/move" do
    it "commits the defender's roll" do
      battle = create(:battle, :active, player_one: opponent, player_two: character)

      post move_battle_path(battle), params: { move_delta: 3 }, as: :json

      expect(response).to have_http_status(:no_content)
      expect(battle.reload.current_turn.move_delta).to eq(3)
    end

    it "answers 422 for a roll further than allowed" do
      battle = create(:battle, :active, player_one: opponent, player_two: character)

      post move_battle_path(battle), params: { move_delta: Battle::MAX_MOVE + 5 }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "POST /battles/:id/expire" do
    it "resolves the turn once the deadline has passed" do
      battle = create(:battle, :active, player_one: character, player_two: opponent)
      battle.current_turn.update!(deadline_at: 1.second.ago)

      post expire_battle_path(battle), as: :json

      expect(response).to have_http_status(:no_content)
      expect(battle.reload.turn_number).to eq(2)
    end

    it "does nothing before the deadline, and still answers success" do
      battle = create(:battle, :active, player_one: character, player_two: opponent)

      post expire_battle_path(battle), as: :json

      expect(response).to have_http_status(:no_content)
      expect(battle.reload.turn_number).to eq(1)
    end
  end
end
