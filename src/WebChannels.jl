"""
Handles WebSockets communication logic.
"""
module WebChannels

import HTTP, Distributed, Logging, JSON3
import Genie, Genie.Renderer

const ClientId = UInt # web socket hash
const ChannelName = String

struct ChannelNotFoundException <: Exception
  name::ChannelName
end

mutable struct ChannelClient
  client::HTTP.WebSockets.WebSocket
  channels::Vector{ChannelName}
end

const ChannelClientsCollection = Dict{ClientId,ChannelClient} # { id(ws) => { :client => ws, :channels => ["foo", "bar", "baz"] } }
const ChannelSubscriptionsCollection = Dict{ChannelName,Vector{ClientId}}  # { "foo" => ["4", "12"] }
const MessagePayload = Union{Nothing,Dict}

mutable struct ChannelMessage
  channel::ChannelName
  client::ClientId
  message::String
  payload::MessagePayload
end

function JSON3.StructTypes.StructType(::Type{T}) where {T<:ChannelMessage}
  JSON3.StructTypes.Struct()
end

const CLIENTS = ChannelClientsCollection()
const SUBSCRIPTIONS = ChannelSubscriptionsCollection()


clients() = collect(values(CLIENTS))
subscriptions() = SUBSCRIPTIONS
websockets() = map(c -> c.client, clients())
channels() = collect(keys(SUBSCRIPTIONS))


function connected_clients(channel::ChannelName) :: Vector{ChannelClient}
  clients = ChannelClient[]
  for client_id in SUBSCRIPTIONS[channel]
    ! (CLIENTS[client_id].client.txclosed && CLIENTS[client_id].client.rxclosed) && push!(clients, CLIENTS[client_id])
  end

  clients
end
function connected_clients() :: Vector{ChannelClient}
  clients = ChannelClient[]
  for ch in channels()
    clients = vcat(clients, connected_clients(ch))
  end

  clients
end


function disconnected_clients(channel::ChannelName) :: Vector{ChannelClient}
  clients = ChannelClient[]
  for client_id in SUBSCRIPTIONS[channel]
    CLIENTS[client_id].client.txclosed && CLIENTS[client_id].client.rxclosed && push!(clients, CLIENTS[client_id])
  end

  clients
end
function disconnected_clients() :: Vector{ChannelClient}
  clients = ChannelClient[]
  for ch in channels()
    clients = vcat(clients, disconnected_clients(ch))
  end

  clients
end


"""
Subscribes a web socket client `ws` to `channel`.
"""
function subscribe(ws::HTTP.WebSockets.WebSocket, channel::ChannelName) :: ChannelClientsCollection
  if haskey(CLIENTS, id(ws))
    in(channel, CLIENTS[id(ws)].channels) || push!(CLIENTS[id(ws)].channels, channel)
  else
    CLIENTS[id(ws)] = ChannelClient(ws, ChannelName[channel])
  end

  push_subscription(id(ws), channel)

  CLIENTS
end


function id(ws::HTTP.WebSockets.WebSocket) :: UInt
  hash(ws)
end


"""
Unsubscribes a web socket client `ws` from `channel`.
"""
function unsubscribe(ws::HTTP.WebSockets.WebSocket, channel::ChannelName) :: ChannelClientsCollection
  haskey(CLIENTS, id(ws)) && deleteat!(CLIENTS[id(ws)].channels, CLIENTS[id(ws)].channels .== channel)
  pop_subscription(id(ws), channel)

  CLIENTS
end
function unsubscribe(channel_client::ChannelClient, channel::ChannelName) :: ChannelClientsCollection
  unsubscribe(channel_client.client, channel)
end


"""
Unsubscribes a web socket client `ws` from all the channels.
"""
function unsubscribe_client(ws::HTTP.WebSockets.WebSocket) :: ChannelClientsCollection
  if haskey(CLIENTS, id(ws))
    for channel_id in CLIENTS[id(ws)].channels
      pop_subscription(id(ws), channel_id)
    end

    delete!(CLIENTS, id(ws))
  end

  CLIENTS
end
function unsubscribe_client(client_id::ClientId) :: ChannelClientsCollection
  unsubscribe_client(CLIENTS[client_id].client)

  CLIENTS
end
function unsubscribe_client(channel_client::ChannelClient) :: ChannelClientsCollection
  unsubscribe_client(channel_client.client)

  CLIENTS
end


"""
unsubscribe_disconnected_clients() :: ChannelClientsCollection

Unsubscribes clients which are no longer connected.
"""
function unsubscribe_disconnected_clients() :: ChannelClientsCollection
  for channel_client in disconnected_clients()
    unsubscribe_client(channel_client)
  end

  CLIENTS
end
function unsubscribe_disconnected_clients(channel::ChannelName) :: ChannelClientsCollection
  for channel_client in disconnected_clients(channel)
    unsubscribe(channel_client, channel)
  end

  CLIENTS
end


"""
Adds a new subscription for `client` to `channel`.
"""
function push_subscription(client_id::ClientId, channel::ChannelName) :: ChannelSubscriptionsCollection
  if haskey(SUBSCRIPTIONS, channel)
    ! in(client_id, SUBSCRIPTIONS[channel]) && push!(SUBSCRIPTIONS[channel], client_id)
  else
    SUBSCRIPTIONS[channel] = ClientId[client_id]
  end

  SUBSCRIPTIONS
end
function push_subscription(channel_client::ChannelClient, channel::ChannelName) :: ChannelSubscriptionsCollection
  push_subscription(id(channel_client.client), channel)
end


"""
Removes the subscription of `client` to `channel`.
"""
function pop_subscription(client::ClientId, channel::ChannelName) :: ChannelSubscriptionsCollection
  if haskey(SUBSCRIPTIONS, channel)
    filter!(SUBSCRIPTIONS[channel]) do (client_id)
      client_id != client
    end
    isempty(SUBSCRIPTIONS[channel]) && delete!(SUBSCRIPTIONS, channel)
  end

  SUBSCRIPTIONS
end
function pop_subscription(channel_client::ChannelClient, channel::ChannelName) :: ChannelSubscriptionsCollection
  pop_subscription(id(channel_client.client), channel)
end


"""
Removes all subscriptions of `client`.
"""
function pop_subscription(channel::ChannelName) :: ChannelSubscriptionsCollection
  if haskey(SUBSCRIPTIONS, channel)
    delete!(SUBSCRIPTIONS, channel)
  end

  SUBSCRIPTIONS
end


"""
Pushes `msg` (and `payload`) to all the clients subscribed to the channels in `channels`, with the exception of `except`.
"""
function broadcast(channels::Union{ChannelName,Vector{ChannelName}},
                    msg::String,
                    payload::Union{Dict,Nothing} = nothing;
                    except::Union{HTTP.WebSockets.WebSocket,Nothing,UInt} = nothing) :: Bool
  isa(channels, Array) || (channels = ChannelName[channels])

  for channel in channels
    haskey(SUBSCRIPTIONS, channel) || throw(ChannelNotFoundException(channel))

    for client in SUBSCRIPTIONS[channel]
      except !== nothing && client == id(except) && continue
      CLIENTS[client].client.txclosed && CLIENTS[client].client.rxclosed && continue

      try
        payload !== nothing ?
          message(client, ChannelMessage(channel, client, msg, payload) |> Renderer.Json.JSONParser.json) :
          message(client, msg)
      catch
      end
    end
  end

  true
end


"""
Pushes `msg` (and `payload`) to all the clients subscribed to the channels in `channels`, with the exception of `except`.
"""
function broadcast(msg::String;
                    channels::Union{Union{ChannelName,Vector{ChannelName}},Nothing} = nothing,
                    payload::Union{Dict,Nothing} = nothing,
                    except::Union{HTTP.WebSockets.WebSocket,Nothing,UInt} = nothing) :: Bool
  channels === nothing && (channels = collect(keys(SUBSCRIPTIONS)))
  broadcast(channels, msg, payload; except = except)
end


"""
Pushes `js_code` (a JavaScript piece of code) to be executed by all the clients subscribed to the channels in `channels`,
with the exception of `except`.
"""
function jscomm(js_code::String, channels::Union{Union{ChannelName,Vector{ChannelName}},Nothing} = nothing;
            except::Union{HTTP.WebSockets.WebSocket,Nothing,UInt} = nothing)
  broadcast(string(Genie.config.webchannels_eval_command, js_code); channels = channels, except = except)
end


"""
Writes `msg` to web socket for `client`.
"""
function message(ws::HTTP.WebSockets.WebSocket, msg::String) :: Int
  write(ws, msg)
end
function message(client::ClientId, msg::String) :: Int
  message(CLIENTS[client].client, msg)
end
function message(client::ChannelClient, msg::String) :: Int
  message(client.client, msg)
end

end
