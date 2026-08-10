# Keeps the lobby live: it tells a waiting player the moment they are matched,
# so nobody has to reload to find out a duel started.
class LobbyChannel < ApplicationCable::Channel
  def subscribed
    character = current_user.character
    return reject unless character

    # Two streams. The personal one carries the match, which is addressed to
    # exactly one player. The shared one carries only how many people are
    # waiting — a number that belongs to nobody, so it is safe to broadcast.
    stream_from self.class.personal_stream(character)
    stream_from self.class.queue_stream
  end

  def self.personal_stream(character)
    "lobby:character:#{character.id}"
  end

  def self.queue_stream
    "lobby:queue"
  end

  def self.matched!(battle)
    [battle.player_one, battle.player_two].each do |character|
      ActionCable.server.broadcast(
        personal_stream(character),
        { type: "matched", battleId: battle.id }
      )
    end
  end

  def self.queue_changed!
    ActionCable.server.broadcast(queue_stream, { type: "queue", waiting: QueueEntry.count })
  end
end
