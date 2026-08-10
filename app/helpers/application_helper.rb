module ApplicationHelper
  # m:ss, for a countdown measured in whole seconds.
  def format_duration(seconds)
    minutes, secs = seconds.to_i.divmod(60)
    format("%d:%02d", minutes, secs)
  end
end
