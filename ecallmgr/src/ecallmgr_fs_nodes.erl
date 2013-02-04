%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2013, 2600Hz INC
%%% @doc
%%%
%%% When connecting to a FreeSWITCH node, we create three processes: one to
%%% handle authentication (directory) requests; one to handle route (dialplan)
%%% requests, and one to monitor the node and various stats about the node.
%%%
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%   Karl Anderson
%%%-----------------------------------------------------------------------------
-module(ecallmgr_fs_nodes).

-behaviour(gen_server).

-export([start_link/0]).
-export([connected/0]).
-export([all_nodes_connected/0]).
-export([add/1, add/2, add/3]).
-export([remove/1]).
-export([is_node_up/1
         ,channels_by_auth_id/1
         ,sync_channels/0, sync_channels/1
         ,flush_node_channels/1
        ]).

-export([account_summary/1]).

-export([init/1
         ,handle_call/3
         ,handle_cast/2
         ,handle_info/2
         ,terminate/2
         ,code_change/3
        ]).

-include("ecallmgr.hrl").

-define(SERVER, ?MODULE).
-define(EXPIRE_CHECK, 60000).

-record(node, {node :: atom()
               ,cookie :: atom()
               ,options = [] :: wh_proplist()
              }).
-type fs_node() :: #node{}.
-type fs_nodes() :: [fs_node(),...] | [].

-record(astats, {billing_ids=sets:new() :: set()
                 ,outbound_flat_rate=sets:new() :: set()
                 ,inbound_flat_rate=sets:new() :: set()
                 ,outbound_per_minute=sets:new() :: set()
                 ,inbound_per_minute=sets:new() :: set()
                 ,resource_consumers=sets:new() :: set()
                }).
-type astats() :: #astats{}.

-record(state, {nodes = [] :: fs_nodes()
                ,preconfigured_lookup :: pid()
               }).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% returns ok or {error, some_error_atom_explaining_more}
-spec add(atom()) -> 'ok' | {'error', 'no_connection'}.
-spec add(atom(), wh_proplist() | atom()) -> 'ok' | {'error', 'no_connection'}.
-spec add(atom(), atom(), wh_proplist() | atom()) -> 'ok' | {'error', 'no_connection'}.

add(Node) -> add(Node, []).

add(Node, Opts) when is_list(Opts) -> add(Node, erlang:get_cookie(), Opts);
add(Node, Cookie) when is_atom(Cookie) -> add(Node, Cookie, [{cookie, Cookie}]).

add(Node, Cookie, Opts) ->
    gen_server:call(?MODULE, {add_fs_node, Node, Cookie
                              ,[{cookie, Cookie} | props:delete(cookie, Opts)]
                             }, 30000).

%% returns ok or {error, some_error_atom_explaining_more}
-spec remove(atom()) -> 'ok'.
remove(Node) -> gen_server:cast(?MODULE, {rm_fs_node, Node}).

-spec connected() -> [atom(),...] | [].
connected() -> gen_server:call(?MODULE, connected_nodes).

-spec is_node_up(atom()) -> boolean().
is_node_up(Node) -> gen_server:call(?MODULE, {is_node_up, Node}).

-spec all_nodes_connected() -> boolean().
all_nodes_connected() ->
    length(ecallmgr_config:get(<<"fs_nodes">>, [])) =:= length(connected()).

-spec account_summary(ne_binary()) -> wh_json:object().
account_summary(AccountId) ->
    summarize_account_usage(ecallmgr_fs_channel:account_summary(AccountId)).

-spec channels_by_auth_id(ne_binary()) ->
                                 {'ok', wh_json:objects()} |
                                 {'error', 'not_found'}.
channels_by_auth_id(AuthorizingId) ->
    MatchSpec = [{#channel{authorizing_id = '$1', _ = '_'}
                  ,[{'=:=', '$1', {const, AuthorizingId}}]
                  ,['$_']}
                ],
    case ets:select(ecallmgr_channels, MatchSpec) of
        [] -> {error, not_found};
        Channels -> {ok, [ecallmgr_fs_channel:record_to_json(Channel)
                          || Channel <- Channels
                         ]}
    end.

-spec sync_channels() -> 'ok'.
-spec sync_channels(string() | binary() | atom()) -> 'ok'.
sync_channels() ->
    _ = [ecallmgr_fs_node:sync_channels(Srv)
         || Srv <- gproc:lookup_pids({p, l, fs_node})
        ],
    ok.

sync_channels(Node) ->
    N = wh_util:to_atom(Node, true),
    _ = [ecallmgr_fs_node:sync_channels(Srv)
         || Srv <- gproc:lookup_pids({p, l, fs_node})
                ,ecallmgr_fs_node:fs_node(Srv) =:= N
        ],
    ok.

-spec flush_node_channels(string() | binary() | atom()) -> 'ok'.
flush_node_channels(Node) ->
    gen_server:cast(?MODULE, {flush_node_channels, wh_util:to_atom(Node, true)}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    put(callid, ?LOG_SYSTEM_ID),
    lager:debug("starting new fs handler"),
    Pid = spawn(fun() -> start_preconfigured_servers() end),
    _ = ets:new(sip_subscriptions, [set, public, named_table, {keypos, #sip_subscription.key}]),
    _ = ets:new(ecallmgr_channels, [set, protected, named_table, {keypos, #channel.uuid}]),
    _ = erlang:send_after(?EXPIRE_CHECK, self(), expire_sip_subscriptions),
    {ok, #state{preconfigured_lookup=Pid}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%% #state{nodes=[{FSNode, HandlerPid}]}
%%--------------------------------------------------------------------
handle_call({is_node_up, Node}, _From, #state{nodes=Nodes}=State) ->
    {reply, [ Node1 || #node{node=Node1} <- Nodes, Node1 =:= Node ] =/= [], State};
handle_call(connected_nodes, _From, #state{nodes=Nodes}=State) ->
    {reply, [ Node || #node{node=Node} <- Nodes ], State};
handle_call({add_fs_node, Node, Cookie, Options}, {Pid, _}, #state{preconfigured_lookup=Pid}=State) ->
    lager:debug("trying to add ~s(~s)", [Node, Cookie]),
    {Resp, State1} = add_fs_node(Node, Cookie, Options, State),
    {reply, Resp, State1, hibernate};
handle_call({add_fs_node, Node, Cookie, Options}, _From, #state{preconfigured_lookup=Pid}=State) ->
    lager:debug("trying to add ~s(~s)", [Node, Cookie]),
    {Resp, State1} = add_fs_node(Node, Cookie, Options, State),
    Pid1 = maybe_stop_preconfigured_lookup(Resp, Pid),
    {reply, Resp, State1#state{preconfigured_lookup=Pid1}, hibernate};
handle_call(_Request, _From, State) ->
    {reply, {error, not_implemented}, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({new_channel, Channel}, State) ->
    ets:insert(ecallmgr_channels, Channel),
    {noreply, State, hibernate};
handle_cast({channel_update, UUID, Update}, State) ->
    ets:update_element(ecallmgr_channels, UUID, Update),
    {noreply, State, hibernate};
handle_cast({destroy_channel, UUID, Node}, State) ->
    MatchSpec = [{#channel{uuid='$1', node='$2', _ = '_'}
                  ,[{'andalso', {'=:=', '$2', {const, Node}}
                     ,{'=:=', '$1', UUID}
                    }
                   ],
                  [true]
                 }],
    N = ets:select_delete(ecallmgr_channels, MatchSpec),
    lager:debug("removed ~p channel(s) with id ~s on ~s", [N, UUID, Node]),
    {noreply, State, hibernate};
handle_cast({rm_fs_node, Node}, State) ->
    {noreply, rm_fs_node(Node, State), hibernate};
handle_cast({sync_channels, Node, Channels}, State) ->
    lager:debug("ensuring channel cache is in sync with ~s", [Node]),
    MatchSpec = [{#channel{uuid = '$1', node = '$2', _ = '_'}
                  ,[{'=:=', '$2', {const, Node}}]
                  ,['$1']}
                ],
    CachedChannels = sets:from_list(ets:select(ecallmgr_channels, MatchSpec)),
    SyncChannels = sets:from_list(Channels),
    Remove = sets:subtract(CachedChannels, SyncChannels),
    Add = sets:subtract(SyncChannels, CachedChannels),
    _ = [begin
             lager:debug("removed channel ~s from cache during sync with ~s", [UUID, Node]),
             ets:delete(ecallmgr_channels, UUID)
         end
         || UUID <- sets:to_list(Remove)
        ],
    _ = [begin
             lager:debug("added channel ~s to cache during sync with ~s", [UUID, Node]),
             case build_channel_record(Node, UUID) of
                 {ok, C} -> ets:insert(ecallmgr_channels, C);
                 {error, _R} -> lager:warning("failed to sync channel ~s: ~p", [UUID, _R])
             end
         end
         || UUID <- sets:to_list(Add)
        ],
    {noreply, State, hibernate};
handle_cast({flush_node_channels, Node}, State) ->
    lager:debug("flushing all channels in cache associated to node ~s", [Node]),
    MatchSpec = [{#channel{node = '$1', _ = '_'}
                  ,[{'=:=', '$1', {const, Node}}]
                  ,['true']}
                ],
    ets:select_delete(ecallmgr_channels, MatchSpec),
    {noreply, State};
handle_cast(_, State) ->
    {noreply, State, hibernate}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({event, [UUID | Props]}, State) ->
    Node = get_node_from_props(Props),
    case props:get_value(<<"Event-Subclass">>, Props, props:get_value(<<"Event-Name">>, Props)) of
        <<"CHANNEL_CREATE">> -> ecallmgr_fs_channel:new(Props, Node);
        <<"CHANNEL_DESTROY">> ->  ecallmgr_fs_channel:destroy(Props, Node);
        <<"channel_move::move_complete">> -> ecallmgr_fs_channel:set_node(Node, UUID);
        <<"CHANNEL_ANSWER">> -> ecallmgr_fs_channel:set_answered(UUID, true);
        <<"CHANNEL_BRIDGE">> ->
            OtherLeg = get_other_leg(UUID, Props),
            ecallmgr_fs_channel:set_bridge(UUID, OtherLeg),
            ecallmgr_fs_channel:set_bridge(OtherLeg, UUID);
        <<"CHANNEL_UNBRIDGE">> ->
            OtherLeg = get_other_leg(UUID, Props),
            ecallmgr_fs_channel:set_bridge(UUID, undefined),
            ecallmgr_fs_channel:set_bridge(OtherLeg, undefined);
        <<"CHANNEL_EXECUTE_COMPLETE">> ->
            Data = props:get_value(<<"Application-Data">>, Props),
            case props:get_value(<<"Application">>, Props) of
                <<"set">> -> process_channel_update(UUID, Data);
                <<"export">> -> process_channel_update(UUID, Data);
                <<"multiset">> -> process_channel_multiset(UUID, Data);
                _Else -> ok
            end;
        _Else -> lager:debug("else: ~p", [_Else])
    end,
    {noreply, State};
handle_info(expire_sip_subscriptions, Cache) ->
    Now = wh_util:current_tstamp(),
    DeleteSpec = [{#sip_subscription{expires = '$1', timestamp = '$2', _ = '_'},
                   [{'>', {const, Now}, {'+', '$2', '$1'}}],
                   [true]}
                 ],
    ets:select_delete(sip_subscriptions, DeleteSpec),
    _ = erlang:send_after(?EXPIRE_CHECK, self(), expire_sip_subscriptions),
    {noreply, Cache, hibernate};
handle_info({nodedown, Node}, #state{nodes=Nodes}=State) ->
    _ = ecallmgr_fs_sup:remove_node(Node),
    Opts = case lists:keyfind(Node, #node.node, Nodes) of
               #node{options=O} -> O;
               false -> []
           end,
    case ecallmgr_fs_pinger_sup:add_node(Node, Opts) of
        {ok, _} ->
            lager:warning("started fs pinger for node '~s'", [Node]),
            NodeBin = amqp_util:encode(wh_util:to_binary(Node)),
            wh_gauge:set(<<"freeswitch.nodes.", NodeBin/binary, ".up">>, 0),
            wh_timer:delete(<<"freeswitch.nodes.", NodeBin/binary, ".uptime">>),
            {noreply, State#state{nodes=lists:keydelete(Node, #node.node, Nodes)}};
        {error, {already_started, _}} ->
            lager:warning("started fs pinger for node '~s'", [Node]),
            NodeBin = amqp_util:encode(wh_util:to_binary(Node)),
            wh_gauge:set(<<"freeswitch.nodes.", NodeBin/binary, ".up">>, 0),
            wh_timer:delete(<<"freeswitch.nodes.", NodeBin/binary, ".uptime">>),
            {noreply, State#state{nodes=lists:keydelete(Node, #node.node, Nodes)}};
        _Else ->
            _ = ecallmgr_fs_pinger_sup:remove_node(Node),
            self() ! {nodedown, Node},
            lager:critical("failed to start fs pinger for node '~s': ~p", [Node, _Else]),
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ets:delete(sip_subscriptions),
    ets:delete(ecallmgr_channels),
    lager:debug("fs nodes termination: ~p", [ _Reason]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec process_channel_multiset(ne_binary(), ne_binary()) -> any().
process_channel_multiset(UUID, Datas) ->
    [process_channel_update(UUID, Data)
     || Data <- binary:split(Datas, <<"|">>, [global])
    ].

-spec process_channel_update(ne_binary(), ne_binary()) -> any().
-spec process_channel_update(ne_binary(), ne_binary(), ne_binary()) -> any().

process_channel_update(UUID, Data) ->
    case binary:split(Data, <<"=">>) of
        [Var, Value] -> process_channel_update(UUID, Var, Value);
        _Else -> ok
    end.

process_channel_update(UUID, <<"ecallmgr_", Var/binary>>, Value) ->
    Normalized = wh_util:to_lower_binary(binary:replace(Var, <<"-">>, <<"_">> , [global])),
    process_channel_update(UUID, Normalized, Value);
process_channel_update(UUID, <<"hold_music">>, _) ->
    ecallmgr_fs_channel:set_import_moh(UUID, false);
process_channel_update(UUID, Var, Value) ->
    try wh_util:to_atom(<<"set_", Var/binary>>) of
        Function ->
            Exports = ecallmgr_fs_channel:module_info(exports),
            case lists:keysearch(Function, 1, Exports) of
                {value, {_, 2}} -> ecallmgr_fs_channel:Function(UUID, Value);
                _Else -> ok
            end
    catch
        _:_ -> ok
    end.

-spec find_cookie(atom(), wh_proplist()) -> atom().
find_cookie('undefined', Options) ->
    wh_util:to_atom(props:get_value(cookie, Options, erlang:get_cookie()));
find_cookie(Cookie, _Opts) when is_atom(Cookie) -> Cookie.

-spec add_fs_node(atom(), atom(), wh_proplist(), #state{}) ->
                         {'ok', #state{}} |
                         {{'error', 'no_connection'}, #state{}} |
                         {{'error', 'failed_starting_handlers'}, #state{}}.
add_fs_node(Node, Cookie, Options, #state{nodes=Nodes}=State) ->
    Cookie = find_cookie(Cookie, Options),
    case lists:keysearch(Node, #node.node, Nodes) of
        false -> maybe_ping_node(Node, Cookie, Options, State);
        {value, #node{}} ->
            lager:info("already connected to node '~s'", [Node]),
            {ok, State}
    end.

-spec maybe_ping_node(atom(), atom(), wh_proplist(), #state{}) ->
                             {'ok', #state{}} |
                             {{'error', 'no_connection'}, #state{}} |
                             {{'error', 'failed_starting_handlers'}, #state{}}.
maybe_ping_node(Node, Cookie, Options, #state{nodes=Nodes}=State) ->
    erlang:set_cookie(Node, Cookie),
    case net_adm:ping(Node) of
        pong ->
            try maybe_start_node_handlers(Node, Cookie, Options) of
                _ ->
                    lager:info("successfully connected to node '~s'", [Node]),
                    _ = update_stats(connect, Node),
                    {ok, State#state{nodes=[#node{node=Node, cookie=Cookie, options=Options}
                                            | lists:keydelete(Node, #node.node, Nodes)
                                           ]}}
            catch
                error:{badmatch, timeout} ->
                    lager:warning("connection timeout while starting node ~s handlers", [Node]),
                    self() ! {nodedown, Node},
                    {{error, failed_starting_handlers}, State};
                _:Reason ->
                    ST = erlang:get_stacktrace(),
                    lager:warning("unable to start node ~s handlers: ~p", [Node, Reason]),
                    _ = [lager:debug("st: ~p", [S]) || S <- ST],
                    self() ! {nodedown, Node},
                    {{error, failed_starting_handlers}, State}
            end;
        pang ->
            lager:warning("unable to connect to node '~s'; ensure it is reachable from this server and using cookie '~s'", [Node, Cookie]),
            self() ! {nodedown, Node},
            {{error, no_connection}, State}
    end.

-spec maybe_start_node_handlers(atom(), atom(), wh_proplist()) -> 'ok'.
maybe_start_node_handlers(Node, Cookie, Options) ->
    Version = get_client_version(Node),
    case ecallmgr_fs_sup:add_node(Node, [{cookie, Cookie}
                                         ,{client_version, Version}
                                         | props:delete(cookie, Options)
                                        ])
    of
        {ok, _} ->
            erlang:monitor_node(Node, true),
            bind_to_fs_events(Version, Node);
        {error, {already_started, _}} ->
            bind_to_fs_events(Version, Node)
    end.

-spec rm_fs_node(atom(), #state{}) -> #state{}.
rm_fs_node(Node, #state{nodes=Nodes}=State) ->
    lager:debug("closing node handler for ~s", [Node]),
    _ = update_stats(disconnect, Node),
    _ = unbind_from_fs_events(Node),
    _ = close_node(Node),
    State#state{nodes=lists:keydelete(Node, #node.node, Nodes)}.

-spec close_node(atom()) ->
                              'ok' |
                              {'error','not_found' | 'running' | 'simple_one_for_one'}.
close_node(Node) ->
    catch erlang:monitor_node(Node, false), % will crash if Node is down already
    _P = ecallmgr_fs_pinger_sup:remove_node(Node),
    lager:debug("stopped pinger: ~p", [_P]),
    ecallmgr_fs_sup:remove_node(Node).

-spec get_client_version(atom()) -> api_binary().
get_client_version(Node) ->
    case freeswitch:version(Node) of
        {ok, Version} -> Version;
        _Else ->
            lager:debug("unable to get freeswitch client version: ~p", [_Else]),
            undefined
    end.

-spec bind_to_fs_events(ne_binary(), atom()) -> 'ok'.
bind_to_fs_events(<<"mod_kazoo", _/binary>>, Node) ->
    ok =  freeswitch:event(Node, ['CHANNEL_CREATE', 'CHANNEL_DESTROY'
                                  ,'CHANNEL_EXECUTE_COMPLETE', 'CHANNEL_ANSWER'
                                  ,'CHANNEL_BRIDGE', 'CHANNEL_UNBRIDGE'
                                  ,'CUSTOM', 'channel_move::move_complete'
                                 ]);
bind_to_fs_events(_Else, Node) ->
    %% gproc throws a badarg if the binding already exists, and since
    %% this is a long running process there are conditions where a
    %% freeswitch server connection flaps and we re-connect before
    %% unbinding.  Therefore, we no longer unbind and we catch the
    %% exception generated by re-reg'n existing bindings. -Karl
    catch gproc:reg({p, l, {event, Node, <<"CHANNEL_CREATE">>}}),
    catch gproc:reg({p, l, {event, Node, <<"CHANNEL_DESTROY">>}}),
    catch gproc:reg({p, l, {event, Node, <<"CHANNEL_ANSWER">>}}),
    catch gproc:reg({p, l, {event, Node, <<"CHANNEL_BRIDGE">>}}),
    catch gproc:reg({p, l, {event, Node, <<"CHANNEL_UNBRIDGE">>}}),
    catch gproc:reg({p, l, {event, Node, <<"channel_move::move_complete">>}}),
    catch gproc:reg({p, l, {event, Node, <<"CHANNEL_EXECUTE_COMPLETE">>}}),
    ok.

-spec unbind_from_fs_events(atom()) -> 'ok'.
unbind_from_fs_events(_Node) ->
    ok.

-spec update_stats(connect|disconnect, atom()) -> 'ok'.
update_stats(connect, Node) ->
    NodeBin = amqp_util:encode(wh_util:to_binary(Node)),
    wh_gauge:set(<<"freeswitch.nodes.", NodeBin/binary, ".up">>, 1),
    wh_timer:update(<<"freeswitch.nodes.", NodeBin/binary, ".uptime">>),
    wh_timer:update(<<"freeswitch.nodes.", NodeBin/binary, ".last_connected">>),
    ok;
update_stats(disconnect, Node) ->
    NodeBin = amqp_util:encode(wh_util:to_binary(Node)),
    wh_gauge:set(<<"freeswitch.nodes.", NodeBin/binary, ".up">>, 0),
    wh_timer:delete(<<"freeswitch.nodes.", NodeBin/binary, ".uptime">>),
    ok.

-spec get_node_from_props(wh_proplist()) -> atom().
get_node_from_props(Props) ->
    case props:get_value(<<"ecallmgr_node">>, Props) of
        undefined -> guess_node_from_props(Props);
        Node -> wh_util:to_atom(Node, true)
    end.

-spec guess_node_from_props(wh_proplist()) -> atom().
guess_node_from_props(Props) ->
    wh_util:to_atom(<<"freeswitch@", (props:get_value(<<"FreeSWITCH-Hostname">>, Props))/binary>>, true).

start_preconfigured_servers() ->
    put(callid, ?LOG_SYSTEM_ID),
    case ecallmgr_config:get(<<"fs_nodes">>) of
        [] ->
            lager:info("no preconfigured servers available. Is the sysconf whapp running?"),
            timer:sleep(5000),
            _ = ecallmgr_config:flush(<<"fs_nodes">>),
            start_preconfigured_servers();
        Nodes when is_list(Nodes) ->
            lager:info("successfully retrieved FreeSWITCH nodes to connect with, doing so..."),
            [start_node_from_config(N) || N <- Nodes];
        _E ->
            lager:debug("recieved a non-list for fs_nodes: ~p", [_E]),
            timer:sleep(5000),
            _ = ecallmgr_config:flush(<<"fs_nodes">>),
            start_preconfigured_servers()
    end.

start_node_from_config(MaybeJObj) ->
    case wh_json:is_json_object(MaybeJObj) of
        false -> ?MODULE:add(wh_util:to_atom(MaybeJObj, true));
        true ->
            {[Cookie], [Node]} = wh_json:get_values(MaybeJObj),
            ?MODULE:add(wh_util:to_atom(Node, true), wh_util:to_atom(Cookie, true))
    end.

-spec maybe_stop_preconfigured_lookup('ok' | {'error', _}, pid() | 'undefined') ->
                                             pid() | 'undefined'.
maybe_stop_preconfigured_lookup(_, 'undefined') -> 'undefined';
maybe_stop_preconfigured_lookup('ok', Pid) ->
    is_pid(Pid) andalso is_process_alive(Pid) andalso exit(Pid, 'kill'),
    'undefined';
maybe_stop_preconfigured_lookup(_, Pid) -> Pid.

-spec build_channel_record(atom(), ne_binary()) ->
                                  {'ok', channel()} |
                                  {'error', 'timeout' | 'badarg'}.
build_channel_record(Node, UUID) ->
    case freeswitch:api(Node, 'uuid_dump', wh_util:to_list(UUID)) of
        {'ok', Dump} ->
            Props = ecallmgr_util:eventstr_to_proplist(Dump),
            {'ok', ecallmgr_fs_channel:props_to_record(Props, Node)};
        {'error', _}=E -> E;
        'timeout' -> {'error', 'timeout'}
    end.

-spec summarize_account_usage(channels()) -> wh_json:object().
summarize_account_usage(Channels) ->
    AStats = lists:foldr(fun classify_channel/2, #astats{}, Channels),
    wh_json:from_list(
      [{<<"Calls">>, sets:size(AStats#astats.billing_ids)}
       ,{<<"Channels">>,  length(Channels)}
       ,{<<"Outbound-Flat-Rate">>, sets:size(AStats#astats.outbound_flat_rate)}
       ,{<<"Inbound-Flat-Rate">>, sets:size(AStats#astats.inbound_flat_rate)}
       ,{<<"Outbound-Per-Minute">>, sets:size(AStats#astats.outbound_per_minute)}
       ,{<<"Inbound-Per-Minute">>, sets:size(AStats#astats.inbound_per_minute)}
       ,{<<"Resource-Consuming-Calls">>, sets:size(AStats#astats.resource_consumers)}
      ]).

-spec classify_channel(channel(), astats()) -> astats().
classify_channel(#channel{billing_id='undefined', uuid=UUID}=Channel, AStats) ->
    classify_channel(Channel#channel{billing_id=wh_util:to_hex_binary(crypto:md5(UUID))}
                     ,AStats
                    );
classify_channel(#channel{bridge_id='undefined', billing_id=BillingId}=Channel, AStats) ->
    classify_channel(Channel#channel{bridge_id=BillingId}, AStats);
classify_channel(#channel{direction = <<"outbound">>
                          ,account_billing = <<"flat_rate">>
                          ,bridge_id=BridgeId
                          ,billing_id=BillingId
                         }
                 ,#astats{outbound_flat_rate=OutboundFlatRates
                          ,resource_consumers=ResourceConsumers
                          ,billing_ids=BillingIds
                         }=AStats) ->
    AStats#astats{outbound_flat_rate=sets:add_element(BridgeId, OutboundFlatRates)
                  ,resource_consumers=sets:add_element(BillingId, ResourceConsumers)
                  ,billing_ids=sets:add_element(BillingId, BillingIds)
                 };
classify_channel(#channel{direction = <<"inbound">>
                          ,account_billing = <<"flat_rate">>
                          ,bridge_id=BridgeId
                          ,billing_id=BillingId
                         }
                 ,#astats{inbound_flat_rate=InboundFlatRates
                          ,resource_consumers=ResourceConsumers
                          ,billing_ids=BillingIds
                         }=AStats) ->
    AStats#astats{inbound_flat_rate=sets:add_element(BridgeId, InboundFlatRates)
                  ,resource_consumers=sets:add_element(BillingId, ResourceConsumers)
                  ,billing_ids=sets:add_element(BillingId, BillingIds)
                 };
classify_channel(#channel{direction = <<"outbound">>
                          ,account_billing = <<"per_minute">>
                          ,bridge_id=BridgeId
                          ,billing_id=BillingId
                         }
                 ,#astats{outbound_per_minute=OutboundPerMinute
                          ,resource_consumers=ResourceConsumers
                          ,billing_ids=BillingIds
                         }=AStats) ->
    AStats#astats{outbound_per_minute=sets:add_element(BridgeId, OutboundPerMinute)
                  ,resource_consumers=sets:add_element(BillingId, ResourceConsumers)
                  ,billing_ids=sets:add_element(BillingId, BillingIds)
                 };
classify_channel(#channel{direction = <<"inbound">>
                          ,account_billing = <<"per_minute">>
                          ,bridge_id=BridgeId
                          ,billing_id=BillingId
                         }
                 ,#astats{inbound_per_minute=InboundPerMinute
                          ,resource_consumers=ResourceConsumers
                          ,billing_ids=BillingIds
                         }=AStats) ->
    AStats#astats{inbound_per_minute=sets:add_element(BridgeId, InboundPerMinute)
                  ,resource_consumers=sets:add_element(BillingId, ResourceConsumers)
                  ,billing_ids=sets:add_element(BillingId, BillingIds)
                 };
classify_channel(#channel{direction = <<"inbound">>
                          ,authorizing_id='undefined'
                          ,billing_id=BillingId
                         }
                 ,#astats{resource_consumers=ResourceConsumers
                          ,billing_ids=BillingIds
                         }=AStats) ->
    AStats#astats{resource_consumers=sets:add_element(BillingId, ResourceConsumers)
                  ,billing_ids=sets:add_element(BillingId, BillingIds)
                 };
classify_channel(#channel{direction = <<"inbound">>
                          ,billing_id=BillingId
                         }
                 ,#astats{billing_ids=BillingIds}=AStats) ->
    AStats#astats{billing_ids=sets:add_element(BillingId, BillingIds)};
classify_channel(#channel{direction = <<"outbound">>
                          ,resource_id='undefined'
                          ,billing_id=BillingId
                         }
                 ,#astats{billing_ids=BillingIds}=AStats) ->
    AStats#astats{billing_ids=sets:add_element(BillingId, BillingIds)};
classify_channel(#channel{direction = <<"outbound">>
                          ,billing_id=BillingId
                         }
                 ,#astats{resource_consumers=ResourceConsumers
                          ,billing_ids=BillingIds
                         }=AStats) ->
    AStats#astats{resource_consumers=sets:add_element(BillingId, ResourceConsumers)
                  ,billing_ids=sets:add_element(BillingId, BillingIds)
                 }.

get_other_leg(UUID, Props) ->
    get_other_leg(UUID, Props, props:get_value(<<"Other-Leg-Unique-ID">>, Props)).

get_other_leg(UUID, Props, 'undefined') ->
    get_other_leg_1(UUID
                    ,props:get_value(<<"Bridge-A-Unique-ID">>, Props)
                    ,props:get_value(<<"Bridge-A-Unique-ID">>, Props)
                   );
get_other_leg(_UUID, _Props, OtherLeg) -> OtherLeg.

get_other_leg_1(UUID, UUID, OtherLeg) -> OtherLeg;
get_other_leg_1(UUID, OtherLeg, UUID) -> OtherLeg.
