class LobbyController < ApplicationController
  before_action :require_character!

  def show
    @ongoing = Battle.where.not(status: :finished)
                     .where(player_one: current_character)
                     .or(Battle.where.not(status: :finished).where(player_two: current_character))
                     .order(created_at: :desc)
  end

  def join
    QueueEntry.find_or_create_by!(character: current_character)
    started = Matchmaker.run!
    LobbyChannel.queue_changed!

    # The match also arrives over the channel, but answering with it here means a
    # player whose socket is down still gets pulled into their duel.
    render json: lobby_state(started.find { |battle| battle.participant?(current_character) })
  end

  def leave
    QueueEntry.where(character: current_character).delete_all
    LobbyChannel.queue_changed!

    render json: lobby_state
  end

  private

  def lobby_state(battle = nil)
    {
      queued: QueueEntry.exists?(character: current_character),
      waiting: QueueEntry.count,
      battleId: battle&.id
    }
  end
  helper_method :lobby_state
end
