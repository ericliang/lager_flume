%% @doc Flume backend for lager.

-module(lager_flume_backend).

-behaviour(gen_event).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-compile([{parse_transform, lager_transform}]).
-endif.

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

-export([config_to_id/1]).

-include_lib("lager/include/lager.hrl").
%%-include_lib("lager.hrl").
-include("gen-erl/thrift_source_protocol_thrift.hrl").
-include("gen-erl/flume_types.hrl").

-record(state, {id, level, formatter, format_config,
				client, last_time, host, port,
				shaper, batch_size, buffer, flush_timer}).

-define(DEFAULT_FORMAT,[date, " ", time,
						" [", severity, "] ",
						{pid, ""},
						{module, [
								  {pid, ["@"], ""},
								  module,
								  {function, [":", function], ""},
								  {line, [":",line], ""}], ""},
						" ", message]).

-define(NET_TIMEOUT, 1000). %% in milliseconds
-define(RECONNECT_INTERVAL, 1000000). %% in microseconds
-define(DEFAULT_BATCH_SIZE, 1).
-define(DEFAULT_FLUSH_INTERVAL, 1000). %% 1s

%% @private
init([Host, Port, Level]) ->
    init([Host, Port, Level, ?DEFAULT_BATCH_SIZE]);

init([Host, Port, Level, BatchSize]) ->
    init([Host, Port, Level, BatchSize, 
		  {lager_default_formatter, ?DEFAULT_FORMAT}]);
init([Host, Port, Level, BatchSize, 
	  {Formatter, FormatterConfig}]) when is_atom(Formatter) ->
    case reconnect(Host, Port) of
        {error, Reason} ->
			{error, Reason};
		{Client, Last} ->
            try parse_level(Level) of
                Lvl ->
					Timer = erlang:send_after(?DEFAULT_FLUSH_INTERVAL,self(),flush),
                    {ok, #state{id = config_to_id([Host, Port, Level]),
								level=Lvl,
								formatter=Formatter,
								format_config=FormatterConfig,
								client = Client,
								last_time = Last,
								host = Host,
								port = Port,
								shaper = #lager_shaper{hwm = undefined},
								batch_size = BatchSize,
								buffer = queue:new(),
								flush_timer = Timer}}
			catch
				_:_ ->
					{error, bad_log_level}
			end
    end.

reconnect(Host, Port, Last) ->
	%% auto-connect should be controled by connect interval, 
	%% to prevent pushing too much pressure to server
	case timer:now_diff(os:timestamp(), Last) >= ?RECONNECT_INTERVAL of
		true ->
			reconnect(Host, Port);
		_ ->
			%% ?INT_LOG(debug, "Reconnect to ~p:~p was limited~n", [Host, Port]),
			{error, rate_limit}
	end.

reconnect(Host, Port) -> 
	case catch  thrift_client_util:new(Host, Port, thrift_source_protocol_thrift,
									   [{framed, true},
										{connect_timeout, ?NET_TIMEOUT},
										{recv_timeout, ?NET_TIMEOUT},
										{sockopts, [{keepalive, true}]}]) of
		{ok, Client} ->
			{Client, os:timestamp()};
		Error ->
			?INT_LOG(error, "Can't connect to flume ~p:~p due to ~p~n",
					[Host, Port, Error]),
			{error, Error}
	end.

%% @private
handle_call(get_loglevel, #state{level=Level} = State) ->
    {ok, Level, State};
handle_call({set_loglevel, Level}, State) ->
    try parse_level(Level) of
        Lvl ->
            {ok, ok, State#state{level=Lvl}}
    catch
        _:_ ->
            {ok, {error, bad_log_level}, State}
    end;
handle_call({set_loghwm, Hwm}, #state{shaper=Shaper} = State) ->
	case is_integer(Hwm) andalso Hwm > 0 of
		true ->
            {ok, ok, State#state{shaper=Shaper#lager_shaper{hwm=Hwm}}};
		false ->
            {ok, {error, bad_log_hwm}, State}
    end;
handle_call({set_log_batchsize, Size}, State) ->
	case is_integer(Size) andalso Size > 0 of
		true ->
            {ok, ok, State#state{batch_size=Size}};
		false ->
            {ok, {error, bad_log_batch_size}, State}
    end;
handle_call(_Request, State) ->
    {ok, ok, State}.

%% @private
handle_event({log, Message}, #state{level = Level,
									client = undefined,
									host = Host, port = Port,
									last_time = Last } = State) ->   
    case lager_util:is_loggable(Message, Level, State#state.id) of
        true ->
			case reconnect(Host, Port, Last) of
				{error, rate_limit} ->
					{ok, State};
				{error, _} ->
					{ok, State#state{last_time = os:timestamp()}};
				{Client1, Last1} ->
					State1 = State#state{client = Client1, last_time = Last1},
					handle_event({log, Message}, State1)
			end;		
        false ->
            {ok, State}
    end;

handle_event({log, Message}, #state{level=Level,
									shaper = Shaper} = State) ->
    case lager_util:is_loggable(Message, Level, State#state.id) of
        true ->
			case lager_util:check_hwm(Shaper) of
				{true, Drop, #lager_shaper{hwm=Hwm} = NewShaper1} ->
					State1 = case Drop > 0 of
								  true ->
									  Report = limit_message(Drop, Hwm),
									  buffering(Report, State);
								  _ ->
									  State
							  end,
					State2 = buffering(Message, State1),
					{ok, State2#state{shaper=NewShaper1}};
				{false, _, NewShaper2} ->
					{ok, State#state{shaper=NewShaper2}}
			end;
        false ->
            {ok, State}
    end;

handle_event(_Event, State) ->
    {ok, State}.

%% @private
handle_info(flush, #state{formatter=Formatter,
						   format_config=FormatConfig,
						   client = Client,
						   buffer = Buffer,
						  flush_timer = Timer} = State) ->
	erlang:cancel_timer(Timer),
	Events = lists:map(
			   fun(Message) ->					   
					   MsgBody = Formatter:format(Message, FormatConfig),
					   #'ThriftFlumeEvent'{body = lists:flatten(MsgBody)}
			   end, queue:to_list(Buffer)),

	Client1 = to_flume(Events, Client),
	Timer1 = erlang:send_after(?DEFAULT_FLUSH_INTERVAL, self(), flush),
	{ok, State#state{client=Client1, buffer = queue:new(), 
					 flush_timer = Timer1}};

handle_info(_Info, State) ->
    {ok, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

limit_message(Drop, Hwm) ->
	LimitMessage = io_lib:format("lager_flume_backend dropped ~p messages in the last second that exceeded the limit of ~p messages/sec", [Drop, Hwm]),
	lager_msg:new(LimitMessage, warning, [], []).

buffering(Message, #state{batch_size = BatchSize,
						  buffer = Buffer} = State) ->
	State1 = State#state{buffer = queue:in(Message, Buffer)},
	case queue:len(State1#state.buffer) >= BatchSize of
		true ->
			{ok, State2} = handle_info(flush, State1),
			State2;
		_ ->
			State1
	end.

to_flume(Event, Client) when is_record(Event, 'ThriftFlumeEvent')->
	thrift_rpc(Client, append, Event);

to_flume([], Client) ->
	Client;

to_flume([Event], Client) when is_record(Event, 'ThriftFlumeEvent')->
	thrift_rpc(Client, append, Event);

to_flume([Event|_] = Events, Client) when is_record(Event, 'ThriftFlumeEvent')->
	thrift_rpc(Client, appendBatch, Events).

thrift_rpc(Client, Func, Arg) ->
	{Client1, Res} = (catch thrift_client:send_call(Client, Func, [Arg])),
	case Res of 
		ok ->
			Client1;
		{exception, Excp} ->
			?INT_LOG(error, "Exception from flume server: ~p~n", [Excp]),
			Client1;
		{badmatch, {error, TcpError}} ->
			?INT_LOG(error , "Tcp error on thrift connection to flume: ~p ~n", 
					 [TcpError]),
			undefined;
		{error, Reason} ->
			?INT_LOG(error, "Error on thrift connection to flume: ~p ~n", 
					 [Reason]),
			undefined;
		Unknown ->
			?INT_LOG(error, "Unknown monster from flume server: ~p~n", [Unknown]),
			undefined
	end.

%% convert the configuration into a hopefully unique gen_event ID
config_to_id([Host, Port, _Level]) ->
    {?MODULE, {Host, Port}};
config_to_id([Host, Port, _Level, _Formatter]) ->
    {?MODULE, {Host, Port}}.

parse_level(Level) ->
    try lager_util:config_to_mask(Level) of
        Res ->
            Res
    catch
        error:undef ->
            %% must be lager < 2.0
            lager_util:level_to_num(Level)
    end.

-ifdef(TEST).


-endif.
