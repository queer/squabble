defmodule Squabble do
  @moduledoc """
  A simple implementation of the raft protocol

  https://raft.github.io/
  """

  use GenServer

  alias Squabble.PG
  alias Squabble.Server
  alias Squabble.State

  require Logger

  @key Squabble
  @election_initial_delay 500
  @election_random_delay 500

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check the state of the election, look for a current leader
  """
  def leader_check(pid) do
    GenServer.cast(pid, {:leader, :check, self()})
  end

  @doc """
  Let the new follower know about the current term and who the leader is
  """
  def notify_of_leader(pid, term) do
    GenServer.cast(pid, {:leader, :notice, self(), node(), term})
  end

  @doc """
  Announce a node as running for leader
  """
  def announce_candidate(pid, term) do
    GenServer.cast(pid, {:election, :running, self(), term})
  end

  @doc """
  Vote for a node as the leader
  """
  def vote_for(pid, term) do
    GenServer.cast(pid, {:election, :cast_vote, self(), term})
  end

  @doc """
  Set the node as the new leader for a term
  """
  def new_leader(pid, term) do
    GenServer.cast(pid, {:election, :winner, self(), node(), term})
  end

  @doc """
  Get debug information out of the squabble server
  """
  def debug() do
    GenServer.call(Squabble, :debug)
  end

  @doc """
  Check if the current node is the leader
  """
  @spec node_is_leader?() :: boolean()
  def node_is_leader?() do
    case :ets.lookup(@key, :is_leader?) do
      [{_, value}] when is_boolean(value) ->
        value

      _ ->
        false
    end
  end

  def init(opts) do
    PG.join()

    table = :ets.new(@key, [:set, :public, :named_table])
    :ets.insert(table, {:is_leader?, false})

    start_election(1)

    :ok = :net_kernel.monitor_nodes(true)

    size = Keyword.get(opts, :size, 1)
    subscriptions = Keyword.get(opts, :subscriptions, [])

    state = %State{
      state: "candidate",
      size: size,
      subscriptions: subscriptions,
      term: 0,
      highest_seen_term: 0,
      votes: [],
      table: table,
    }

    {:ok, state, {:continue, {:election, :check}}}
  end

  def handle_continue({:election, :check}, state) do
    {:ok, state} = Server.look_for_leader(state)
    {:noreply, state}
  end

  def handle_call(:state, _from, state) do
    {:reply, Map.put(state, :node, node()), state}
  end

  def handle_call(:debug, _from, state) do
    debug = Server.debug(state)
    {:reply, debug, state}
  end

  def handle_cast({:leader, :check, pid}, state) do
    {:ok, state} = Server.leader_check(state, pid)
    {:noreply, state}
  end

  def handle_cast({:leader, :notice, leader_pid, leader_node, term}, state) do
    {:ok, state} = Server.set_leader(state, leader_pid, leader_node, term)
    {:noreply, state}
  end

  def handle_cast({:election, :running, pid, term}, state) do
    {:ok, state} = Server.vote_leader(state, pid, term)
    {:noreply, state}
  end

  def handle_cast({:election, :cast_vote, pid, term}, state) do
    {:ok, state} = Server.vote_received(state, pid, term)
    {:noreply, state}
  end

  def handle_cast({:election, :winner, leader_pid, leader_node, term}, state) do
    {:ok, state} = Server.set_leader(state, leader_pid, leader_node, term)
    {:noreply, state}
  end

  def handle_info({:election, :start, term}, state) do
    {:ok, state} = Server.start_election(state, term)
    {:noreply, state}
  end

  def handle_info({:election, :check_election_status, term}, state) do
    {:ok, state} = Server.check_election_status(state, term)
    {:noreply, state}
  end

  def handle_info({:nodeup, _node}, state) do
    Process.send_after(self(), :assert_leader, 300)
    {:noreply, state}
  end

  def handle_info({:nodedown, node}, state) do
    {:ok, state} = Server.node_down(state, node)
    {:noreply, state}
  end

  def handle_info(:assert_leader, state) do
    {:ok, state} = Server.assert_leader(state)
    {:noreply, state}
  end

  def start_election(term) do
    Process.send_after(
      self(),
      {:election, :start, term},
      @election_initial_delay + :rand.uniform(@election_random_delay)
    )
  end
end
