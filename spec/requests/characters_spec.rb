require "rails_helper"

RSpec.describe "Characters", type: :request do
  let(:user) { create(:user) }

  describe "GET /character/new" do
    it "offers the form to a signed-in user with no character yet" do
      sign_in user

      get new_character_path

      expect(response).to have_http_status(:ok)
    end

    it "sends someone who already has a character back to their profile" do
      user.create_character!(name: "Already Here")
      sign_in user

      get new_character_path

      expect(response).to redirect_to(root_path)
    end

    it "requires sign-in" do
      get new_character_path

      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "POST /character" do
    it "creates the character and lands on the profile" do
      sign_in user

      post character_path, params: { character: { name: "Fresh Commander" } }

      expect(response).to redirect_to(root_path)
      expect(user.reload.character.name).to eq("Fresh Commander")
    end

    it "re-renders the form when the name is missing" do
      sign_in user

      post character_path, params: { character: { name: "" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.reload.character).to be_nil
    end
  end

  describe "GET /character" do
    it "shows the signed-in commander's own profile" do
      character = create(:character, user: user, level: 3, life: 70, life_replenished_at: Time.current)
      sign_in user

      get character_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(character.name)
      expect(response.body).to include("COMMANDER LEVEL")
    end

    it "sends a user with no character yet to create one" do
      sign_in user

      get character_path

      expect(response).to redirect_to(new_character_path)
    end
  end
end
