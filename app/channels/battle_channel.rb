# Pushes the whole battle state to both players as JSON so neither browser ever
# has to re-fetch the page to stay in sync.
class BattleChannel < ApplicationCable::Channel
  def subscribed
    battle = Battle.find_by(id: params[:id])

    return reject unless battle&.participant?(current_user.character)

    stream_for battle
  end
end
