class ApplicationController < ActionController::Base
  before_action :authenticate_user!, unless: :devise_controller?
  before_action :hold_player_in_battle, unless: :devise_controller?

  private

  def current_character
    current_user&.character
  end
  helper_method :current_character

  def require_character!
    redirect_to new_character_path, alert: "Create a character first" unless current_character
  end

  # A commander with a duel running belongs in it: no queueing for a second one,
  # no wandering off. Finish it first.
  #
  # This lives here and applies by default rather than being switched on per
  # controller, so a page added later is covered without anyone having to
  # remember it exists. The only way out is finishing the battle — or signing
  # out, since Devise is excluded above.
  def hold_player_in_battle
    battle = current_character&.ongoing_battle
    return if battle.nil?

    # Everything under the battle's own path is how you finish it: the page
    # itself, the state refetch, and the moves. Matching on the path rather
    # than naming controllers keeps that true for anything added to the battle
    # later, and it is what stops the redirect chasing its own tail.
    home = battle_path(battle)
    return if request.path == home || request.path.start_with?("#{home}/")

    if request.format.json?
      render json: { error: "Finish your battle first", battleId: battle.id }, status: :conflict
    else
      # No flash: landing back on your own battle says it well enough.
      redirect_to home
    end
  end
end
