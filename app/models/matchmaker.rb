# Turns the waiting queue into battles. It runs after every join, so usually it
# pairs one couple or nobody — but it loops, so a pool that is already several
# deep empties into as many battles as it holds: four waiting become two duels.
module Matchmaker
  module_function

  def run!
    started = []

    loop do
      battle = pair_next!
      break if battle.nil?

      started << battle
    end

    started
  end

  # Claims the two who have waited longest, one row at a time and checked each
  # time, rather than under a database lock — that keeps it correct on SQLite.
  # delete_all reports how many rows it really removed, so when a concurrent
  # join takes our partner first we put our own claim back, keeping its place in
  # line, instead of dropping that player out of the queue entirely.
  def pair_next!
    waiting = QueueEntry.in_line.limit(2).to_a
    return nil unless waiting.size == 2

    first, second = waiting
    return nil unless claim(first)

    unless claim(second)
      restore(first)
      return nil
    end

    start_battle(first.character, second.character)
  end

  def claim(entry)
    QueueEntry.where(id: entry.id).delete_all == 1
  end

  def restore(entry)
    return if QueueEntry.exists?(character_id: entry.character_id)

    QueueEntry.create!(character_id: entry.character_id, created_at: entry.created_at)
  end

  # Queueing is consent, so the duel starts at once instead of waiting to be
  # accepted. If these two already have something unfinished between them —
  # only possible if they were paired before and one side never actually
  # entered the finished battle — that is the battle they get, since only one
  # battle per pair may be open at a time.
  def start_battle(one, two)
    pair = [one.id, two.id]
    battle = Battle.where.not(status: :finished)
                   .find_by(player_one_id: pair, player_two_id: pair)
    battle ||= Battle.create!(player_one: one, player_two: two, status: :pending)
    battle.accept! if battle.pending?

    LobbyChannel.matched!(battle)
    battle
  end
end
