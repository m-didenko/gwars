module ApplicationHelper
  # m:ss, for a countdown measured in whole seconds.
  def format_duration(seconds)
    minutes, secs = seconds.to_i.divmod(60)
    format("%d:%02d", minutes, secs)
  end

  # The queue widget's starting state. Shared between LobbyController's JSON
  # responses (join/leave) and the character page, which renders the same
  # widget's initial markup — both need the same shape.
  def lobby_state(battle = nil)
    {
      queued: QueueEntry.exists?(character: current_character),
      waiting: QueueEntry.count,
      battleId: battle&.id
    }
  end
end
