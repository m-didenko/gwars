require "rails_helper"

# ApplicationController itself has no routes of its own, so its behavior is
# only observable through the controllers that inherit its before_actions.
# What is worth pinning down here, specifically, is that these are default-on
# for every controller rather than something each new page has to opt into.
RSpec.describe "ApplicationController", type: :request do
  describe "authenticate_user!" do
    it "sends a signed-out visitor to sign in, whichever page they asked for" do
      get root_path

      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "require_character!" do
    let(:user) { create(:user) }

    before { sign_in user }

    it "sends a character-less commander to create one before joining the queue" do
      post join_lobby_path

      expect(response).to redirect_to(new_character_path)
    end

    it "sends a character-less commander to create one before dueling" do
      get battles_path

      expect(response).to redirect_to(new_character_path)
    end
  end

  describe "hold_player_in_battle" do
    let(:one) { create(:character) }
    let(:two) { create(:character) }
    let(:battle) { create(:battle, :active, player_one: one, player_two: two) }

    before { sign_in one.user }

    # The guard is wired in once on ApplicationController rather than added
    # per controller, so any page — including the character page, which is
    # root — has to redirect without anyone remembering to add it there.
    it "holds the root page (the character profile)" do
      battle # eager-load before the request

      get root_path

      expect(response).to redirect_to(battle_path(battle))
    end

    it "holds the battles (duels) page" do
      battle # eager-load before the request

      get battles_path

      expect(response).to redirect_to(battle_path(battle))
    end

    # Devise is excluded by name, not by path, which is what makes this work:
    # signing out is the one way out of a battle that is not "finish it".
    it "still lets a commander sign out from the middle of a battle" do
      battle

      delete destroy_user_session_path

      expect(response).not_to redirect_to(battle_path(battle))
    end
  end
end
