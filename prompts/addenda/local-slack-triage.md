# The Slack queue, on the device
- Always pass the step's `channel_id` to a reply, reaction, schedule or mark: that is how
  the queue knows it was this conversation. Follow the write's result; call
  `slack_triage_next` afterwards only when that result does not carry the next one.
