type ChannelHandle a = | ChannelOpaque
type ChannelError = | ChannelClosed | InvalidCapacity(requested: Int)
type Task a = | TaskOpaque
type TaskResult a = | Done(value: a) | Failed(message: Text) | Cancelled

once effect Channel a where {
  channel.open : (Int) -> Result ChannelError (ChannelHandle a)
  channel.send : (ChannelHandle a, a) -> Result ChannelError ()
  channel.recv : (ChannelHandle a) -> Result ChannelError a
  channel.close : (ChannelHandle a) -> ()
}

once effect Async a where {
  async.spawn : (() ->{Async | e} a) -> Task a
  async.await : (Task a) -> TaskResult a
  async.cancel : (Task a) -> ()
  async.yield : () -> ()
}

open-channel(capacity) = channel.open(capacity)
send-one(channel, value) = channel.send(channel, value)
recv-one(channel) = channel.recv(channel)
close-channel(channel) = channel.close(channel)
spawn-send(channel, value) = async.spawn(fn () -> channel.send(channel, value))
