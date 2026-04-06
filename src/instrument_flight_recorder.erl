%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Flight recorder using Erlang's seq_trace for low-overhead message tracing.
%%
%% This module captures message passing events at VM level with minimal overhead,
%% correlating them with OpenTelemetry spans via trace_id labels.
%%
%% seq_trace tokens propagate automatically with messages between processes,
%% allowing full message flow visibility within a trace.
%%
%% == Example Usage ==
%% ```
%% %% Flight recorder starts enabled by default
%% instrument_tracer:with_span(<<"request">>, fun() ->
%%   %% All message passing captured with trace_id label
%%   gen_server:call(some_server, request),
%%   another_process ! message
%% end),
%%
%% %% On error or slow request, dump the trace
%% TraceId = instrument_tracer:trace_id(),
%% Events = instrument_flight_recorder:get_trace(TraceId).
%% '''
-module(instrument_flight_recorder).
-author("benoitc").

-behaviour(gen_server).

%% API
-export([
  start_link/0,
  start_link/1,
  enable/0,
  disable/0,
  is_enabled/0,
  get_trace/1,
  dump_trace/1,
  dump_all/0,
  clear/0,
  mark/1,
  mark/2,
  stats/0,
  set_buffer_size/1
]).

%% gen_server callbacks
-export([
  init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3
]).

-define(SERVER, ?MODULE).
-define(BUFFER_TABLE, instrument_flight_buffer).
-define(DEFAULT_BUFFER_SIZE, 65536).  %% 64K events
-define(ENABLED_KEY, '$instrument_flight_recorder_enabled').

-record(state, {
  buffer_size :: pos_integer()
}).

%% ============================================================================
%% API
%% ============================================================================

%% @doc Starts the flight recorder with default options.
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
  start_link([]).

%% @doc Starts the flight recorder with options.
-spec start_link(list()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Args) ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, Args, []).

%% @doc Enables the flight recorder.
%% Registers as seq_trace system tracer and starts capturing events.
-spec enable() -> ok.
enable() ->
  gen_server:call(?SERVER, enable).

%% @doc Disables the flight recorder.
%% Unregisters as seq_trace system tracer. Buffer is retained.
-spec disable() -> ok.
disable() ->
  gen_server:call(?SERVER, disable).

%% @doc Checks if the flight recorder is enabled.
-spec is_enabled() -> boolean().
is_enabled() ->
  persistent_term:get(?ENABLED_KEY, false).

%% @doc Gets all events for a trace ID.
%% Returns events as a list of {Timestamp, Event} tuples.
-spec get_trace(binary() | integer()) -> [{integer(), term()}].
get_trace(TraceId) when is_binary(TraceId) ->
  %% Convert binary trace_id to integer label
  Label = binary:decode_unsigned(TraceId),
  get_trace(Label);
get_trace(Label) when is_integer(Label) ->
  try
    ets:select(?BUFFER_TABLE, [
      {{'$1', Label, '$2'}, [], [{{'$1', '$2'}}]}
    ])
  catch
    error:badarg -> []
  end.

%% @doc Gets and clears all events for a trace ID.
-spec dump_trace(binary() | integer()) -> [{integer(), term()}].
dump_trace(TraceId) when is_binary(TraceId) ->
  Label = binary:decode_unsigned(TraceId),
  dump_trace(Label);
dump_trace(Label) when is_integer(Label) ->
  Events = get_trace(Label),
  %% Delete matching events
  try
    ets:select_delete(?BUFFER_TABLE, [
      {{'_', Label, '_'}, [], [true]}
    ])
  catch
    error:badarg -> ok
  end,
  Events.

%% @doc Gets all events in the buffer.
-spec dump_all() -> [{integer(), integer(), term()}].
dump_all() ->
  try
    ets:select(?BUFFER_TABLE, [
      {{'$1', '$2', '$3'}, [], [{{'$1', '$2', '$3'}}]}
    ])
  catch
    error:badarg -> []
  end.

%% @doc Clears all events from the buffer.
-spec clear() -> ok.
clear() ->
  gen_server:call(?SERVER, clear).

%% @doc Adds a custom marker event with current trace context.
-spec mark(binary()) -> ok.
mark(Name) ->
  mark(Name, #{}).

%% @doc Adds a custom marker event with metadata.
-spec mark(binary(), map()) -> ok.
mark(Name, Meta) when is_binary(Name), is_map(Meta) ->
  case is_enabled() of
    false -> ok;
    true ->
      %% Get current trace label from seq_trace token
      Label = case seq_trace:get_token(label) of
        {label, L} -> L;
        [] -> 0  %% No active trace
      end,
      Timestamp = erlang:monotonic_time(),
      Key = {Timestamp, erlang:unique_integer([monotonic])},
      Event = {marker, Name, Meta},
      try
        ets:insert(?BUFFER_TABLE, {Key, Label, Event})
      catch
        error:badarg -> ok
      end,
      ok
  end.

%% @doc Returns statistics about the flight recorder.
-spec stats() -> map().
stats() ->
  gen_server:call(?SERVER, stats).

%% @doc Sets the buffer size (for testing). Takes effect immediately.
-spec set_buffer_size(pos_integer()) -> ok.
set_buffer_size(Size) when is_integer(Size), Size > 0 ->
  gen_server:call(?SERVER, {set_buffer_size, Size}).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init(_Args) ->
  BufferSize = application:get_env(instrument, flight_recorder_buffer_size, ?DEFAULT_BUFFER_SIZE),
  AutoEnable = application:get_env(instrument, flight_recorder_auto_enable, true),

  %% Create ETS table for ring buffer
  ets:new(?BUFFER_TABLE, [
    named_table,
    ordered_set,
    public,
    {write_concurrency, true}
  ]),

  %% Initialize state
  State = #state{buffer_size = BufferSize},

  %% Enable by default for production use
  case AutoEnable of
    true ->
      seq_trace:set_system_tracer(self()),
      persistent_term:put(?ENABLED_KEY, true);
    false ->
      persistent_term:put(?ENABLED_KEY, false)
  end,

  {ok, State}.

handle_call(enable, _From, State) ->
  seq_trace:set_system_tracer(self()),
  persistent_term:put(?ENABLED_KEY, true),
  {reply, ok, State};

handle_call(disable, _From, State) ->
  seq_trace:set_system_tracer(false),
  persistent_term:put(?ENABLED_KEY, false),
  {reply, ok, State};

handle_call(clear, _From, State) ->
  ets:delete_all_objects(?BUFFER_TABLE),
  {reply, ok, State};

handle_call(stats, _From, #state{buffer_size = BufferSize} = State) ->
  TableSize = try ets:info(?BUFFER_TABLE, size) catch _:_ -> 0 end,
  Stats = #{
    enabled => is_enabled(),
    buffer_size => BufferSize,
    table_size => TableSize
  },
  {reply, Stats, State};

handle_call({set_buffer_size, Size}, _From, State) ->
  {reply, ok, State#state{buffer_size = Size}};

handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

%% Receive seq_trace events with timestamp
handle_info({seq_trace, Label, Info, Timestamp}, State) ->
  Key = {Timestamp, erlang:unique_integer([monotonic])},
  ets:insert(?BUFFER_TABLE, {Key, Label, Info}),
  maybe_evict(State);

%% Receive seq_trace events without timestamp
handle_info({seq_trace, Label, Info}, State) ->
  Timestamp = erlang:monotonic_time(),
  Key = {Timestamp, erlang:unique_integer([monotonic])},
  ets:insert(?BUFFER_TABLE, {Key, Label, Info}),
  maybe_evict(State);

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  %% Unregister as system tracer
  catch seq_trace:set_system_tracer(false),
  persistent_term:put(?ENABLED_KEY, false),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ============================================================================
%% Internal Functions
%% ============================================================================

%% @private Evicts oldest entries when buffer is full.
maybe_evict(#state{buffer_size = Max} = State) ->
  TableSize = ets:info(?BUFFER_TABLE, size),
  case TableSize > Max of
    true ->
      %% Evict oldest entries until we're back at buffer size
      evict_oldest(TableSize - Max),
      {noreply, State};
    false ->
      {noreply, State}
  end.

%% @private Evicts N oldest entries from the buffer.
evict_oldest(0) ->
  ok;
evict_oldest(N) when N > 0 ->
  case ets:first(?BUFFER_TABLE) of
    '$end_of_table' ->
      ok;
    Key ->
      ets:delete(?BUFFER_TABLE, Key),
      evict_oldest(N - 1)
  end.
