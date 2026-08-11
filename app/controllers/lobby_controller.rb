class LobbyController < ApplicationController
  include ApplicationHelper # lobby_state is shared with the character page's widget

  before_action :require_character!

  def join
    unless current_character.ready_for_battle?
      return render json: { error: "You are still recovering. Wait for your life to reach 90." },
                    status: :unprocessable_entity
    end

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
end
